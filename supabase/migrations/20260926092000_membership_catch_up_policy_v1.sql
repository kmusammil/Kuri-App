-- MEMBERSHIP-004: explicit catch-up policy for late-joining members.
-- FULL creates installment obligations for completed historical cycles as catch-up,
-- while NONE creates obligations only for non-completed/non-cancelled cycles.
-- Historical draw eligibility is not changed by this migration.

ALTER TABLE public.memberships
  ADD COLUMN IF NOT EXISTS catch_up_policy text NOT NULL DEFAULT 'NONE';

ALTER TABLE public.memberships
  DROP CONSTRAINT IF EXISTS memberships_catch_up_policy_check;

ALTER TABLE public.memberships
  ADD CONSTRAINT memberships_catch_up_policy_check
  CHECK (catch_up_policy IN ('NONE','FULL'));

CREATE OR REPLACE FUNCTION public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  target_membership_number text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  RETURN public.create_membership_for_admin(
    target_kuri_id,
    target_person_id,
    target_membership_number,
    'NONE'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  target_membership_number text,
  p_catch_up_policy text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
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
  normalized_catch_up_policy text := upper(coalesce(nullif(btrim(p_catch_up_policy), ''), 'NONE'));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF normalized_catch_up_policy NOT IN ('NONE','FULL') THEN
    RAISE EXCEPTION 'Invalid catch-up policy. Use NONE or FULL.';
  END IF;

  SELECT k.organization_id,k.status,k.enrollment_closed_at,k.membership_limit
    INTO target_org_id,target_kuri_status,target_enrollment_closed_at,target_limit
  FROM public.kuris k
  WHERE k.id=target_kuri_id
  FOR UPDATE;

  IF target_org_id IS NULL THEN
    RAISE EXCEPTION 'Kuri not found.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to add memberships.';
  END IF;

  IF target_kuri_status NOT IN ('OPEN','ACTIVE') THEN
    RAISE EXCEPTION 'Memberships can only be added to an OPEN or ACTIVE Kuri.';
  END IF;

  IF target_enrollment_closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'Kuri enrollment is closed; new memberships cannot be added.';
  END IF;

  SELECT EXISTS(
    SELECT 1
    FROM public.people p
    WHERE p.id=target_person_id
      AND p.organization_id=target_org_id
  ) INTO person_exists;

  IF NOT person_exists THEN
    RAISE EXCEPTION 'Person not found in this organization.';
  END IF;

  SELECT count(*) INTO current_membership_count
  FROM public.memberships m
  WHERE m.kuri_id=target_kuri_id;

  IF current_membership_count>=target_limit THEN
    RAISE EXCEPTION 'Kuri membership limit has been reached.';
  END IF;

  INSERT INTO public.memberships(
    kuri_id,person_id,membership_number,status,catch_up_policy
  )
  VALUES(
    target_kuri_id,
    target_person_id,
    nullif(btrim(target_membership_number),''),
    'ACTIVE',
    normalized_catch_up_policy
  )
  RETURNING id INTO membership_id_value;

  FOR cycle_row IN
    SELECT c.id,c.due_date,c.status
    FROM public.cycles c
    WHERE c.kuri_id=target_kuri_id
      AND (
        normalized_catch_up_policy='FULL'
        OR c.status NOT IN ('COMPLETED','CANCELLED')
      )
      AND c.status <> 'CANCELLED'
    ORDER BY c.cycle_number
  LOOP
    INSERT INTO public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    SELECT
      membership_id_value,
      cycle_row.id,
      k.installment_amount,
      0,
      'UNPAID'::public.installment_status,
      cycle_row.due_date
    FROM public.kuris k
    WHERE k.id=target_kuri_id
    ON CONFLICT(membership_id,cycle_id) DO NOTHING;
  END LOOP;

  PERFORM public.sync_expense_obligations_for_membership(membership_id_value);

  RETURN membership_id_value;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_membership_for_admin(uuid,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_membership_for_admin(uuid,uuid,text) TO authenticated;

REVOKE ALL ON FUNCTION public.create_membership_for_admin(uuid,uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_membership_for_admin(uuid,uuid,text,text) TO authenticated;
