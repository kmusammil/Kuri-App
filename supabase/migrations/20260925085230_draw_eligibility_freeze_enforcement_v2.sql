BEGIN;

CREATE OR REPLACE FUNCTION public.run_random_draw_for_admin(target_cycle_id uuid, selection_count integer DEFAULT 1)
 RETURNS TABLE(selection_order integer, membership_id uuid, membership_number text, registered_name text, display_name text, randomization_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  session_id uuid;
  candidate_count integer;
  draw_status_value public.draw_status;
  cycle_status_value public.cycle_status;
  target_kuri_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF selection_count IS NULL OR selection_count<1 THEN
    RAISE EXCEPTION 'Selection count must be at least 1.';
  END IF;

  SELECT d.id,d.status,c.status,c.kuri_id
    INTO session_id,draw_status_value,cycle_status_value,target_kuri_id
  FROM public.draw_sessions d
  JOIN public.cycles c ON c.id=d.cycle_id
  WHERE d.cycle_id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF d,c;

  IF session_id IS NULL THEN
    RAISE EXCEPTION 'Prepare the draw first.';
  END IF;

  IF cycle_status_value<>'DRAW_PENDING' THEN
    RAISE EXCEPTION 'Cycle must be DRAW_PENDING before running the draw.';
  END IF;

  IF draw_status_value<>'POOL_READY' THEN
    RAISE EXCEPTION 'Draw must be POOL_READY before running the random draw.';
  END IF;

  -- Eligibility is frozen at POOL_READY. Do not recalculate against live
  -- installment/member state here. A system-ineligible frozen entry may only
  -- be included when an explicit admin override was recorded.
  IF EXISTS (
    SELECT 1
    FROM public.draw_pool_entries e
    WHERE e.draw_session_id=session_id
      AND e.admin_included
      AND NOT e.system_eligible
      AND NOT e.override
  ) THEN
    RAISE EXCEPTION 'Draw pool contains an ineligible membership without an override.';
  END IF;

  SELECT count(*) INTO candidate_count
  FROM public.draw_pool_entries e
  WHERE e.draw_session_id=session_id
    AND e.admin_included;

  IF candidate_count=0 THEN
    RAISE EXCEPTION 'No memberships are included in the draw pool.';
  END IF;

  IF selection_count>candidate_count THEN
    RAISE EXCEPTION 'Selection count exceeds the draw pool.';
  END IF;

  PERFORM public.transition_draw_status_for_admin(session_id,'DRAWING');

  DELETE FROM public.draw_selections
  WHERE draw_session_id=session_id;

  INSERT INTO public.draw_selections(
    draw_session_id,membership_id,selection_order,randomization_id
  )
  SELECT
    session_id,picked.membership_id,picked.rn,gen_random_uuid()::text
  FROM (
    SELECT
      e.membership_id,
      row_number() OVER (ORDER BY random())::integer rn
    FROM public.draw_pool_entries e
    WHERE e.draw_session_id=session_id
      AND e.admin_included
    ORDER BY random()
    LIMIT selection_count
  ) picked;

  PERFORM public.transition_draw_status_for_admin(session_id,'RESULTS_READY');

  RETURN QUERY
  SELECT
    s.selection_order,
    s.membership_id,
    m.membership_number,
    p.registered_name,
    p.display_name,
    s.randomization_id
  FROM public.draw_selections s
  JOIN public.memberships m ON m.id=s.membership_id
  JOIN public.people p ON p.id=m.person_id
  WHERE s.draw_session_id=session_id
  ORDER BY s.selection_order;
END;
$function$


REVOKE ALL ON FUNCTION public.run_random_draw_for_admin(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.run_random_draw_for_admin(uuid,integer) TO authenticated;

COMMIT;