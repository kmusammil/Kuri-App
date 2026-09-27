BEGIN;

ALTER TABLE public.kuris
  ADD COLUMN IF NOT EXISTS enrollment_closed_at timestamptz,
  ADD COLUMN IF NOT EXISTS actual_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS completed_at timestamptz,
  ADD COLUMN IF NOT EXISTS archived_at timestamptz;

CREATE OR REPLACE FUNCTION public.close_kuri_enrollment_for_admin(target_kuri_id uuid)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  current_status public.kuri_status;
  target_closed_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT k.status,k.enrollment_closed_at
    INTO current_status,target_closed_at
  FROM public.kuris k
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(
      k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kuri not found or you do not have permission to manage enrollment.';
  END IF;

  IF current_status<>'OPEN' THEN
    RAISE EXCEPTION 'Kuri enrollment can only be closed while the Kuri is OPEN.';
  END IF;

  IF target_closed_at IS NULL THEN
    UPDATE public.kuris
    SET enrollment_closed_at=now(),updated_at=now()
    WHERE id=target_kuri_id
    RETURNING enrollment_closed_at INTO target_closed_at;
  END IF;

  RETURN target_closed_at;
END;
$function$


CREATE OR REPLACE FUNCTION public.transition_kuri_status_for_admin(target_kuri_id uuid, target_status kuri_status)
 RETURNS kuri_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  current_status public.kuri_status;
  target_org_id uuid;
  configured_cycles integer;
  actual_cycles integer;
  nonterminal_cycles integer;
  enrollment_closed_at_value timestamptz;
  actual_started_at_value timestamptz;
  completed_at_value timestamptz;
  archived_at_value timestamptz;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT k.status,k.organization_id,k.number_of_cycles,
         k.enrollment_closed_at,k.actual_started_at,k.completed_at,k.archived_at
    INTO current_status,target_org_id,configured_cycles,
         enrollment_closed_at_value,actual_started_at_value,
         completed_at_value,archived_at_value
  FROM public.kuris k
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(
      k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF target_org_id IS NULL THEN
    RAISE EXCEPTION 'Kuri not found or you do not have permission to change this Kuri status.';
  END IF;

  IF current_status=target_status THEN
    RETURN current_status;
  END IF;

  IF NOT (
    (current_status='DRAFT' AND target_status='OPEN')
    OR (current_status='OPEN' AND target_status='ACTIVE')
    OR (current_status='ACTIVE' AND target_status='COMPLETED')
    OR (current_status='COMPLETED' AND target_status='ARCHIVED')
  ) THEN
    RAISE EXCEPTION 'Invalid Kuri status transition: % -> %.',current_status,target_status;
  END IF;

  IF current_status='OPEN' AND target_status='ACTIVE' THEN
    IF enrollment_closed_at_value IS NULL THEN
      RAISE EXCEPTION 'Kuri enrollment must be explicitly closed before the Kuri can start.';
    END IF;
    actual_started_at_value:=coalesce(actual_started_at_value,now());
  END IF;

  IF current_status='ACTIVE' AND target_status='COMPLETED' THEN
    SELECT count(*) INTO actual_cycles
    FROM public.cycles c
    WHERE c.kuri_id=target_kuri_id;

    SELECT count(*) INTO nonterminal_cycles
    FROM public.cycles c
    WHERE c.kuri_id=target_kuri_id
      AND c.status NOT IN ('COMPLETED','CANCELLED');

    IF actual_cycles<>configured_cycles THEN
      RAISE EXCEPTION 'Kuri cannot be completed until all configured cycles exist.';
    END IF;

    IF nonterminal_cycles>0 THEN
      RAISE EXCEPTION 'Kuri cannot be completed while cycles are not completed or cancelled.';
    END IF;

    completed_at_value:=coalesce(completed_at_value,now());
  END IF;

  IF current_status='COMPLETED' AND target_status='ARCHIVED' THEN
    archived_at_value:=coalesce(archived_at_value,now());
  END IF;

  UPDATE public.kuris
  SET status=target_status,
      actual_started_at=actual_started_at_value,
      completed_at=completed_at_value,
      archived_at=archived_at_value,
      updated_at=now()
  WHERE id=target_kuri_id;

  RETURN target_status;
END;
$function$


CREATE OR REPLACE FUNCTION public.create_membership_for_admin(target_kuri_id uuid, target_person_id uuid, target_membership_number text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  membership_id_value uuid;
  target_org_id uuid;
  target_kuri_status public.kuri_status;
  target_enrollment_closed_at timestamptz;
  target_limit integer;
  current_membership_count integer;
  cycle_row record;
  person_exists boolean;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT k.organization_id,k.status,k.enrollment_closed_at,k.membership_limit
    INTO target_org_id,target_kuri_status,target_enrollment_closed_at,target_limit
  FROM public.kuris k
  WHERE k.id=target_kuri_id
  FOR UPDATE;

  IF target_org_id IS NULL THEN RAISE EXCEPTION 'Kuri not found.'; END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to add memberships.';
  END IF;

  IF target_kuri_status NOT IN ('OPEN','ACTIVE') THEN
    RAISE EXCEPTION 'Memberships can only be added to an OPEN or ACTIVE Kuri.';
  END IF;

  IF target_kuri_status='OPEN' AND target_enrollment_closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Kuri enrollment is closed; use the controlled late-joining workflow.';
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.people p
    WHERE p.id=target_person_id AND p.organization_id=target_org_id
  ) INTO person_exists;

  IF NOT person_exists THEN RAISE EXCEPTION 'Person not found in this organization.'; END IF;

  SELECT count(*) INTO current_membership_count
  FROM public.memberships m
  WHERE m.kuri_id=target_kuri_id;

  IF current_membership_count>=target_limit THEN
    RAISE EXCEPTION 'Kuri membership limit has been reached.';
  END IF;

  INSERT INTO public.memberships(kuri_id,person_id,membership_number,status)
  VALUES(target_kuri_id,target_person_id,nullif(btrim(target_membership_number),''),'ACTIVE')
  RETURNING id INTO membership_id_value;

  FOR cycle_row IN
    SELECT c.id,c.due_date
    FROM public.cycles c
    WHERE c.kuri_id=target_kuri_id
      AND c.status NOT IN ('COMPLETED','CANCELLED')
    ORDER BY c.cycle_number
  LOOP
    INSERT INTO public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    SELECT membership_id_value,cycle_row.id,k.installment_amount,0,
           'UNPAID'::public.installment_status,cycle_row.due_date
    FROM public.kuris k
    WHERE k.id=target_kuri_id
    ON CONFLICT(membership_id,cycle_id) DO NOTHING;
  END LOOP;

  RETURN membership_id_value;
END;
$function$


REVOKE ALL ON FUNCTION public.close_kuri_enrollment_for_admin(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.close_kuri_enrollment_for_admin(uuid) TO authenticated;

COMMIT;