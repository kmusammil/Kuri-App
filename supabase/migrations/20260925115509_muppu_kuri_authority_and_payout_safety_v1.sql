BEGIN;

CREATE OR REPLACE FUNCTION public.enforce_muppu_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE
  cycle_kuri_id uuid;
  person_org_id uuid;
  kuri_org_id uuid;
BEGIN
  SELECT c.kuri_id INTO cycle_kuri_id
  FROM public.cycles c
  WHERE c.id=NEW.cycle_id;

  IF cycle_kuri_id IS NULL OR cycle_kuri_id<>NEW.kuri_id THEN
    RAISE EXCEPTION 'Muppu cycle does not belong to the same Kuri.';
  END IF;

  SELECT p.organization_id INTO person_org_id
  FROM public.people p
  WHERE p.id=NEW.person_id;

  SELECT k.organization_id INTO kuri_org_id
  FROM public.kuris k
  WHERE k.id=NEW.kuri_id;

  IF person_org_id IS NULL OR kuri_org_id IS NULL OR person_org_id<>kuri_org_id THEN
    RAISE EXCEPTION 'Muppu person does not belong to the same organization as the Kuri.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.kuri_id=NEW.kuri_id
      AND m.person_id=NEW.person_id
  ) THEN
    RAISE EXCEPTION 'Muppu person must belong to the Kuri.';
  END IF;

  IF NEW.amount<0 THEN
    RAISE EXCEPTION 'Muppu amount cannot be negative.';
  END IF;

  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS muppu_records_identity_guard ON public.muppu_records;

CREATE TRIGGER muppu_records_identity_guard
BEFORE INSERT OR UPDATE ON public.muppu_records
FOR EACH ROW EXECUTE FUNCTION public.enforce_muppu_identity();

CREATE OR REPLACE FUNCTION public.create_muppu_record_for_admin(
  target_kuri_id uuid,
  target_cycle_id uuid,
  target_person_id uuid,
  target_amount bigint
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $function$
DECLARE
  v_id uuid;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF target_amount IS NULL OR target_amount<0 THEN
    RAISE EXCEPTION 'Muppu amount cannot be negative.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to manage Muppu for this Kuri.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.cycles c
    WHERE c.id=target_cycle_id
      AND c.kuri_id=target_kuri_id
  ) THEN
    RAISE EXCEPTION 'Kuri or cycle not found.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.kuri_id=target_kuri_id
      AND m.person_id=target_person_id
  ) THEN
    RAISE EXCEPTION 'Person does not belong to this Kuri.';
  END IF;

  INSERT INTO public.muppu_records(kuri_id,cycle_id,person_id,amount,status)
  VALUES(target_kuri_id,target_cycle_id,target_person_id,target_amount,'UNPAID')
  RETURNING id INTO v_id;

  RETURN v_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.list_muppu_records_for_admin(
  target_kuri_id uuid DEFAULT NULL,
  target_cycle_id uuid DEFAULT NULL
)
RETURNS TABLE(
  muppu_id uuid,kuri_id uuid,kuri_name text,cycle_id uuid,cycle_number integer,
  person_id uuid,registered_name text,display_name text,amount bigint,
  status public.muppu_status,settlement_method public.muppu_settlement_method,
  paid_at timestamptz,payment_reference text,created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path='public'
AS $function$
  SELECT mr.id,mr.kuri_id,k.name,mr.cycle_id,c.cycle_number,mr.person_id,
         p.registered_name,p.display_name,mr.amount,mr.status,
         mr.settlement_method,mr.paid_at,mr.payment_reference,mr.created_at
  FROM public.muppu_records mr
  JOIN public.kuris k ON k.id=mr.kuri_id
  JOIN public.cycles c ON c.id=mr.cycle_id
  JOIN public.people p ON p.id=mr.person_id
  WHERE (target_kuri_id IS NULL OR mr.kuri_id=target_kuri_id)
    AND (target_cycle_id IS NULL OR mr.cycle_id=target_cycle_id)
    AND public.has_kuri_admin_role(
      mr.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY c.cycle_number DESC,p.display_name,p.registered_name;
$function$;

CREATE OR REPLACE FUNCTION public.mark_muppu_paid_for_admin(
  target_muppu_id uuid,
  paid_payment_reference text DEFAULT NULL,
  paid_at_value timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='public'
AS $function$
DECLARE v_kuri_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT mr.kuri_id INTO v_kuri_id
  FROM public.muppu_records mr
  WHERE mr.id=target_muppu_id
  FOR UPDATE;

  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Muppu record not found.'; END IF;

  IF NOT public.has_kuri_admin_role(
    v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to manage Muppu for this Kuri.';
  END IF;

  UPDATE public.muppu_records mr
  SET status='PAID',
      settlement_method='PAID_IN_ADVANCE',
      paid_at=coalesce(paid_at_value,now()),
      payment_reference=nullif(btrim(paid_payment_reference),'')
  WHERE mr.id=target_muppu_id AND mr.status='UNPAID';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only unpaid Muppu records can be marked paid.';
  END IF;
END
$function$;

CREATE OR REPLACE FUNCTION public.waive_muppu_for_admin(
  target_muppu_id uuid, waiver_reference text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='public'
AS $function$
DECLARE v_kuri_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT mr.kuri_id INTO v_kuri_id
  FROM public.muppu_records mr
  WHERE mr.id=target_muppu_id
  FOR UPDATE;

  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Muppu record not found.'; END IF;

  IF NOT public.has_kuri_admin_role(
    v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to manage Muppu for this Kuri.';
  END IF;

  UPDATE public.muppu_records mr
  SET status='WAIVED',
      settlement_method='WAIVED',
      payment_reference=nullif(btrim(waiver_reference),'')
  WHERE mr.id=target_muppu_id AND mr.status='UNPAID';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only unpaid Muppu records can be waived.';
  END IF;
END
$function$;

CREATE OR REPLACE FUNCTION public.deduct_muppu_from_prize_for_admin(
  target_muppu_id uuid, deduction_reference text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='public'
AS $function$
DECLARE
  v_kuri_id uuid;
  v_cycle_id uuid;
  v_person_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT mr.kuri_id,mr.cycle_id,mr.person_id
  INTO v_kuri_id,v_cycle_id,v_person_id
  FROM public.muppu_records mr
  WHERE mr.id=target_muppu_id
  FOR UPDATE;

  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Muppu record not found.'; END IF;

  IF NOT public.has_kuri_admin_role(
    v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to manage Muppu for this Kuri.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.monthly_winners mw
    JOIN public.payouts po ON po.monthly_winner_id=mw.id
    WHERE mw.cycle_id=v_cycle_id
      AND mw.person_id=v_person_id
      AND po.status<>'PENDING'
  ) THEN
    RAISE EXCEPTION 'Muppu cannot be deducted from prize after payout processing has started.';
  END IF;

  UPDATE public.muppu_records mr
  SET status='DEDUCTED',
      settlement_method='DEDUCTED_FROM_PRIZE',
      payment_reference=nullif(btrim(deduction_reference),'')
  WHERE mr.id=target_muppu_id AND mr.status='UNPAID';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Only unpaid Muppu records can be deducted.';
  END IF;
END
$function$;

GRANT EXECUTE ON FUNCTION public.create_muppu_record_for_admin(uuid,uuid,uuid,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_muppu_records_for_admin(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_muppu_paid_for_admin(uuid,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.waive_muppu_for_admin(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_muppu_from_prize_for_admin(uuid,text) TO authenticated;

REVOKE ALL ON FUNCTION public.create_muppu_record_for_admin(uuid,uuid,uuid,bigint) FROM anon,public;
REVOKE ALL ON FUNCTION public.list_muppu_records_for_admin(uuid,uuid) FROM anon,public;
REVOKE ALL ON FUNCTION public.mark_muppu_paid_for_admin(uuid,text,timestamptz) FROM anon,public;
REVOKE ALL ON FUNCTION public.waive_muppu_for_admin(uuid,text) FROM anon,public;
REVOKE ALL ON FUNCTION public.deduct_muppu_from_prize_for_admin(uuid,text) FROM anon,public;
REVOKE ALL ON FUNCTION public.enforce_muppu_identity() FROM anon,authenticated,public;

COMMIT;
