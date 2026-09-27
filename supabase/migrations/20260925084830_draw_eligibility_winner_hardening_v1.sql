BEGIN;

CREATE OR REPLACE FUNCTION public.prepare_draw_for_admin(target_cycle_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  session_id uuid;
  cycle_kuri_id uuid;
  cycle_status_value public.cycle_status;
  draw_status_value public.draw_status;
  actor_db_user_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT c.kuri_id,c.status
    INTO cycle_kuri_id,cycle_status_value
  FROM public.cycles c
  WHERE c.id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF cycle_kuri_id IS NULL THEN
    RAISE EXCEPTION 'You do not have permission to manage this draw.';
  END IF;

  IF cycle_status_value NOT IN ('PAYMENT_CLOSED','DRAW_PENDING') THEN
    RAISE EXCEPTION 'Cycle must be PAYMENT_CLOSED or DRAW_PENDING before preparing a draw.';
  END IF;

  actor_db_user_id := (SELECT id FROM public.users WHERE id=auth.uid());

  SELECT d.id,d.status
    INTO session_id,draw_status_value
  FROM public.draw_sessions d
  WHERE d.cycle_id=target_cycle_id
    AND d.kuri_id=cycle_kuri_id
  FOR UPDATE;

  IF session_id IS NULL THEN
    INSERT INTO public.draw_sessions(
      kuri_id,cycle_id,conducted_by,status,started_at
    )
    VALUES(
      cycle_kuri_id,target_cycle_id,actor_db_user_id,'DRAFT',now()
    )
    ON CONFLICT (kuri_id,cycle_id) DO NOTHING
    RETURNING id,status INTO session_id,draw_status_value;

    IF session_id IS NULL THEN
      SELECT d.id,d.status
        INTO session_id,draw_status_value
      FROM public.draw_sessions d
      WHERE d.cycle_id=target_cycle_id
        AND d.kuri_id=cycle_kuri_id
      FOR UPDATE;
    END IF;
  END IF;

  IF session_id IS NULL THEN
    RAISE EXCEPTION 'Unable to create or resolve the draw session.';
  END IF;

  IF draw_status_value NOT IN ('DRAFT','POOL_READY') THEN
    RAISE EXCEPTION 'Draw session is already finalized or otherwise unavailable for preparation.';
  END IF;

  -- Once the snapshot is frozen, preparation becomes an idempotent read.
  IF draw_status_value='POOL_READY' THEN
    RETURN session_id;
  END IF;

  -- DRAFT is the only state in which system eligibility may be evaluated.
  -- Rebuilding a DRAFT session is safe because the snapshot has not yet frozen.
  INSERT INTO public.draw_pool_entries(
    draw_session_id,
    membership_id,
    system_eligible,
    admin_included,
    override,
    override_reason,
    modified_by,
    modified_at
  )
  SELECT
    session_id,
    m.id,
    (m.status='ACTIVE' AND i.status IN ('PAID','PAID_LATE')),
    (m.status='ACTIVE' AND i.status IN ('PAID','PAID_LATE')),
    false,
    null,
    actor_db_user_id,
    now()
  FROM public.memberships m
  JOIN public.installments i ON i.membership_id=m.id
  WHERE i.cycle_id=target_cycle_id
    AND m.kuri_id=cycle_kuri_id
  ON CONFLICT(draw_session_id,membership_id) DO NOTHING;

  UPDATE public.draw_pool_entries e
  SET system_eligible=(m.status='ACTIVE' AND i.status IN ('PAID','PAID_LATE')),
      admin_included=CASE
        WHEN e.override THEN e.admin_included
        ELSE (m.status='ACTIVE' AND i.status IN ('PAID','PAID_LATE'))
      END,
      override=CASE WHEN e.override THEN e.override ELSE false END,
      override_reason=CASE WHEN e.override THEN e.override_reason ELSE null END,
      modified_by=actor_db_user_id,
      modified_at=now()
  FROM public.memberships m
  JOIN public.installments i ON i.membership_id=m.id
  WHERE e.draw_session_id=session_id
    AND e.membership_id=m.id
    AND i.cycle_id=target_cycle_id
    AND m.kuri_id=cycle_kuri_id;

  DELETE FROM public.draw_selections
  WHERE draw_session_id=session_id;

  PERFORM public.transition_draw_status_for_admin(session_id,'POOL_READY');

  RETURN session_id;
END;
$function$


CREATE OR REPLACE FUNCTION public.transition_draw_status_for_admin(target_draw_session_id uuid, target_status draw_status)
 RETURNS draw_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  current_status public.draw_status;
  org_id uuid;
  target_kuri_id uuid;
  target_cycle_id uuid;
  included_count integer;
  selection_count integer;
  winner_count integer;
  cycle_status public.cycle_status;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT d.status,d.cycle_id,d.kuri_id,k.organization_id,c.status
    INTO current_status,target_cycle_id,target_kuri_id,org_id,cycle_status
  FROM public.draw_sessions d
  JOIN public.kuris k ON k.id=d.kuri_id
  JOIN public.cycles c ON c.id=d.cycle_id
  WHERE d.id=target_draw_session_id
  FOR UPDATE OF d,k,c;

  IF target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Draw session not found.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to change this draw status.';
  END IF;

  IF current_status=target_status THEN
    RETURN current_status;
  END IF;

  IF NOT (
    (current_status='DRAFT' AND target_status='POOL_READY')
    OR (current_status='POOL_READY' AND target_status IN ('DRAWING','CANCELLED'))
    OR (current_status='DRAWING' AND target_status IN ('RESULTS_READY','CANCELLED'))
    OR (current_status='RESULTS_READY' AND target_status='FINALIZED')
  ) THEN
    RAISE EXCEPTION 'Invalid draw status transition: % -> %.',current_status,target_status;
  END IF;

  IF target_status='POOL_READY' THEN
    SELECT count(*) INTO included_count
    FROM public.draw_pool_entries e
    WHERE e.draw_session_id=target_draw_session_id
      AND e.admin_included;

    IF included_count<1 THEN
      RAISE EXCEPTION 'Draw cannot become POOL_READY without an included pool entry.';
    END IF;

  ELSIF target_status='DRAWING' THEN
    IF cycle_status<>'DRAW_PENDING' THEN
      RAISE EXCEPTION 'Draw can only start while the cycle is DRAW_PENDING.';
    END IF;

    SELECT count(*) INTO included_count
    FROM public.draw_pool_entries e
    WHERE e.draw_session_id=target_draw_session_id
      AND e.admin_included;

    IF included_count<1 THEN
      RAISE EXCEPTION 'Draw cannot start without an included pool.';
    END IF;

  ELSIF target_status='RESULTS_READY' THEN
    SELECT count(*) INTO selection_count
    FROM public.draw_selections s
    WHERE s.draw_session_id=target_draw_session_id;

    IF selection_count<1 THEN
      RAISE EXCEPTION 'Draw cannot become RESULTS_READY without selections.';
    END IF;

  ELSIF target_status='FINALIZED' THEN
    IF cycle_status<>'DRAW_PENDING' THEN
      RAISE EXCEPTION 'Draw cannot be finalized unless the cycle is DRAW_PENDING.';
    END IF;

    SELECT count(*) INTO selection_count
    FROM public.draw_selections s
    WHERE s.draw_session_id=target_draw_session_id;

    SELECT count(*) INTO winner_count
    FROM public.monthly_winners mw
    WHERE mw.cycle_id=target_cycle_id;

    IF selection_count<1 THEN
      RAISE EXCEPTION 'Draw cannot be finalized without selections.';
    END IF;

    IF winner_count<1 THEN
      RAISE EXCEPTION 'Draw cannot be finalized before at least one winner is finalized.';
    END IF;
  END IF;

  UPDATE public.draw_sessions
  SET status=target_status,
      started_at=CASE
        WHEN target_status='DRAWING' THEN coalesce(started_at,now())
        ELSE started_at
      END,
      completed_at=CASE
        WHEN target_status IN ('RESULTS_READY','FINALIZED','CANCELLED')
          THEN coalesce(completed_at,now())
        ELSE completed_at
      END
  WHERE id=target_draw_session_id;

  RETURN target_status;
END;
$function$


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

  IF EXISTS (
    SELECT 1
    FROM public.draw_pool_entries e
    JOIN public.memberships m ON m.id=e.membership_id
    JOIN public.installments i
      ON i.membership_id=m.id
     AND i.cycle_id=target_cycle_id
    WHERE e.draw_session_id=session_id
      AND e.admin_included
      AND NOT (m.status='ACTIVE' AND i.status IN ('PAID','PAID_LATE'))
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


CREATE OR REPLACE FUNCTION public.set_draw_pool_entry_for_admin(target_entry_id uuid, include_in_draw boolean, reason_text text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  target_kuri_id uuid;
  session_status public.draw_status;
  system_eligible_value boolean;
  target_session_id uuid;
BEGIN
  SELECT d.kuri_id,d.id,d.status,e.system_eligible
    INTO target_kuri_id,target_session_id,session_status,system_eligible_value
  FROM public.draw_pool_entries e
  JOIN public.draw_sessions d ON d.id=e.draw_session_id
  WHERE e.id=target_entry_id
  FOR UPDATE OF e,d;

  IF target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Draw pool entry not found.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to modify this draw pool.';
  END IF;

  IF session_status<>'POOL_READY' THEN
    RAISE EXCEPTION 'Draw pool can only be modified while the draw is POOL_READY.';
  END IF;

  IF include_in_draw
     AND NOT system_eligible_value
     AND nullif(btrim(reason_text),'') IS NULL THEN
    RAISE EXCEPTION 'Including a system-ineligible membership requires a reason.';
  END IF;

  UPDATE public.draw_pool_entries
  SET admin_included=include_in_draw,
      override=(include_in_draw<>system_eligible_value),
      override_reason=CASE
        WHEN include_in_draw<>system_eligible_value THEN nullif(btrim(reason_text),'')
        ELSE null
      END,
      modified_by=(SELECT id FROM public.users WHERE id=auth.uid()),
      modified_at=now()
  WHERE id=target_entry_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Draw pool entry not found.';
  END IF;
END;
$function$


CREATE OR REPLACE FUNCTION public.finalize_draw_for_admin(target_cycle_id uuid, final_membership_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  session_id uuid;
  target_kuri_id uuid;
  winner_count integer;
  selected_count integer;
  selected_person_count integer;
  unwon_member_count integer;
  remaining_cycles integer;
  max_winners integer;
  cycle_status_value public.cycle_status;
  draw_status_value public.draw_status;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF final_membership_ids IS NULL
     OR coalesce(array_length(final_membership_ids,1),0)<1 THEN
    RAISE EXCEPTION 'Select at least one winner.';
  END IF;

  IF cardinality(final_membership_ids) <>
     cardinality(array(select distinct unnest(final_membership_ids))) THEN
    RAISE EXCEPTION 'Duplicate winner memberships are not allowed.';
  END IF;

  SELECT d.id,c.kuri_id,c.status,d.status
    INTO session_id,target_kuri_id,cycle_status_value,draw_status_value
  FROM public.draw_sessions d
  JOIN public.cycles c ON c.id=d.cycle_id
  WHERE d.cycle_id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF d,c;

  IF session_id IS NULL THEN
    RAISE EXCEPTION 'Prepare and run the draw before finalizing winners.';
  END IF;

  -- Serialize all winner finalization within this Kuri, including different
  -- cycles, so no-repeat cannot be bypassed by concurrent finalizers.
  PERFORM 1
  FROM public.kuris k
  WHERE k.id=target_kuri_id
  FOR UPDATE;

  SELECT d.status INTO draw_status_value
  FROM public.draw_sessions d
  WHERE d.id=session_id
  FOR UPDATE;

  IF cycle_status_value<>'DRAW_PENDING' THEN
    RAISE EXCEPTION 'Cycle must be DRAW_PENDING before finalizing winners.';
  END IF;

  IF draw_status_value<>'RESULTS_READY' THEN
    RAISE EXCEPTION 'Draw must have RESULTS_READY status before finalizing winners.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.monthly_winners
    WHERE cycle_id=target_cycle_id
  ) THEN
    RAISE EXCEPTION 'Winners are already finalized for this cycle.';
  END IF;

  SELECT count(*)
    INTO selected_count
  FROM public.draw_selections s
  WHERE s.draw_session_id=session_id
    AND s.membership_id=ANY(final_membership_ids);

  IF selected_count<>array_length(final_membership_ids,1) THEN
    RAISE EXCEPTION 'Final winners must come from the current draw selections.';
  END IF;

  SELECT count(DISTINCT m.person_id)
    INTO selected_person_count
  FROM public.memberships m
  WHERE m.id=ANY(final_membership_ids);

  IF selected_person_count<>array_length(final_membership_ids,1) THEN
    RAISE EXCEPTION 'Only one winner per person can be finalized in a cycle.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.id=ANY(final_membership_ids)
      AND (m.kuri_id<>target_kuri_id OR m.status<>'ACTIVE')
  ) THEN
    RAISE EXCEPTION 'A final winner must be an ACTIVE membership in the draw Kuri.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.memberships m
    JOIN public.monthly_winners mw ON mw.person_id=m.person_id
    JOIN public.cycles wc ON wc.id=mw.cycle_id
    WHERE m.id=ANY(final_membership_ids)
      AND wc.kuri_id=target_kuri_id
      AND wc.id<>target_cycle_id
  ) THEN
    RAISE EXCEPTION 'A person who has already won in this Kuri cannot win again.';
  END IF;

  SELECT count(DISTINCT m.person_id)
    INTO unwon_member_count
  FROM public.memberships m
  WHERE m.kuri_id=target_kuri_id
    AND m.status='ACTIVE'
    AND NOT EXISTS (
      SELECT 1
      FROM public.monthly_winners mw
      JOIN public.cycles wc ON wc.id=mw.cycle_id
      WHERE wc.kuri_id=target_kuri_id
        AND mw.person_id=m.person_id
    );

  SELECT greatest(
    k.number_of_cycles-c.cycle_number+1,
    0
  )
    INTO remaining_cycles
  FROM public.kuris k
  JOIN public.cycles c ON c.kuri_id=k.id
  WHERE k.id=target_kuri_id
    AND c.id=target_cycle_id;

  IF remaining_cycles<1 THEN
    RAISE EXCEPTION 'Unable to determine remaining cycles for winner finalization.';
  END IF;

  IF unwon_member_count<remaining_cycles THEN
    RAISE EXCEPTION 'Insufficient remaining members for the remaining cycles; repeating winners is not allowed.';
  END IF;

  max_winners:=unwon_member_count-(remaining_cycles-1);

  IF array_length(final_membership_ids,1)>max_winners THEN
    RAISE EXCEPTION 'Selected winner count exceeds the maximum feasible winner count of %.',max_winners;
  END IF;

  INSERT INTO public.monthly_winners(
    cycle_id,person_id,selection_source,finalized_by,finalized_at
  )
  SELECT
    target_cycle_id,
    m.person_id,
    'RANDOM_DRAW',
    (SELECT id FROM public.users WHERE id=auth.uid()),
    now()
  FROM public.memberships m
  WHERE m.id=ANY(final_membership_ids)
  GROUP BY m.person_id;

  INSERT INTO public.monthly_winner_memberships(
    monthly_winner_id,membership_id
  )
  SELECT mw.id,m.id
  FROM public.monthly_winners mw
  JOIN public.memberships m ON m.person_id=mw.person_id
  WHERE mw.cycle_id=target_cycle_id
    AND m.id=ANY(final_membership_ids);

  PERFORM public.transition_draw_status_for_admin(session_id,'FINALIZED');
  PERFORM public.transition_cycle_status_for_admin(target_cycle_id,'COMPLETED');

  SELECT count(*) INTO winner_count
  FROM public.monthly_winners
  WHERE cycle_id=target_cycle_id;

  RETURN winner_count;
END;
$function$


REVOKE ALL ON FUNCTION public.transition_draw_status_for_admin(uuid,public.draw_status) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.prepare_draw_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.set_draw_pool_entry_for_admin(uuid,boolean,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.run_random_draw_for_admin(uuid,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.finalize_draw_for_admin(uuid,uuid[]) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.transition_draw_status_for_admin(uuid,public.draw_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_draw_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_draw_pool_entry_for_admin(uuid,boolean,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.run_random_draw_for_admin(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_draw_for_admin(uuid,uuid[]) TO authenticated;

COMMIT;