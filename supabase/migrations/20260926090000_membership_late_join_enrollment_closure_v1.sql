-- MEMBERSHIP-001: enforce enrollment closure for all controlled membership additions.
-- Late joining is allowed only while enrollment remains open.
-- Once enrollment_closed_at is set, direct/admin membership creation must stop.
-- Join-request and invitation paths already enforce their own admission policy.

CREATE OR REPLACE FUNCTION public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  target_membership_number text
)
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
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
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
    SELECT 1 FROM public.people p
    WHERE p.id=target_person_id AND p.organization_id=target_org_id
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

  PERFORM public.sync_expense_obligations_for_membership(membership_id_value);

  RETURN membership_id_value;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.create_membership_for_admin(uuid,uuid,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_membership_for_admin(uuid,uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_membership_for_admin(uuid,uuid,text) TO authenticated;
