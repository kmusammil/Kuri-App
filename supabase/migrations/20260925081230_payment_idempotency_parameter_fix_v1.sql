BEGIN;

DROP FUNCTION public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text);

DROP FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint);

CREATE FUNCTION public.create_payment_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  payment_amount bigint,
  payment_date timestamptz,
  payment_method public.payment_method,
  payment_reference text,
  payment_notes text,
  p_idempotency_key text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  payment_id uuid;
  target_org_id uuid;
  v_actor_user_id uuid := (select auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF payment_amount<=0 THEN RAISE EXCEPTION 'Payment amount must be greater than zero.'; END IF;

  request_hash := encode(extensions.digest(
    jsonb_build_array(
      target_kuri_id::text,target_person_id::text,payment_amount::text,
      payment_date::text,payment_method::text,
      coalesce(btrim(payment_reference),''),coalesce(btrim(payment_notes),'')
    )::text,'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(
    actor_user_id,kuri_id,operation_type,idempotency_key,request_hash
  )
  VALUES(v_actor_user_id,target_kuri_id,'PAYMENT_CREATE',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id
    AND f.operation_type='PAYMENT_CREATE'
    AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different payment request.';
  END IF;
  IF idem_row.status='COMPLETED' THEN
    RETURN idem_row.result_payment_id;
  END IF;

  SELECT k.organization_id INTO target_org_id
  FROM public.kuris k WHERE k.id=target_kuri_id;
  IF target_org_id IS NULL THEN RAISE EXCEPTION 'Kuri not found.'; END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to record payments for this Kuri.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.kuri_id=target_kuri_id
      AND m.person_id=target_person_id
  ) THEN
    RAISE EXCEPTION 'Person is not a member of this Kuri.';
  END IF;

  INSERT INTO public.payments(
    kuri_id,organization_id,person_id,amount,payment_date,method,
    reference_number,status,notes
  )
  VALUES(
    target_kuri_id,target_org_id,target_person_id,payment_amount,payment_date,
    payment_method,nullif(btrim(payment_reference),''),
    'APPROVED',nullif(btrim(payment_notes),'')
  )
  RETURNING id INTO payment_id;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_payment_id=payment_id,completed_at=now()
  WHERE id=idem_row.id;

  RETURN payment_id;
END $$;

CREATE FUNCTION public.allocate_payment_for_admin(
  target_payment_id uuid,
  target_installment_id uuid,
  allocation_amount bigint,
  p_idempotency_key text
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  v_actor_user_id uuid := (select auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
  payment_person_id uuid;
  payment_total bigint;
  payment_status public.payment_status;
  payment_kuri_id uuid;
  installment_person_id uuid;
  installment_amount_due bigint;
  target_kuri_id uuid;
  already_allocated bigint;
  installment_allocated bigint;
  next_paid bigint;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF allocation_amount<=0 THEN RAISE EXCEPTION 'Allocation amount must be greater than zero.'; END IF;

  request_hash := encode(extensions.digest(
    jsonb_build_array(
      target_payment_id::text,target_installment_id::text,allocation_amount::text
    )::text,'sha256'),'hex');

  SELECT p.person_id,p.amount,p.status,p.kuri_id
    INTO payment_person_id,payment_total,payment_status,payment_kuri_id
  FROM public.payments p
  WHERE p.id=target_payment_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;

  SELECT i.amount_due,m.person_id,k.id
    INTO installment_amount_due,installment_person_id,target_kuri_id
  FROM public.installments i
  JOIN public.memberships m ON m.id=i.membership_id
  JOIN public.kuris k ON k.id=m.kuri_id
  WHERE i.id=target_installment_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Installment not found.'; END IF;

  IF payment_kuri_id<>target_kuri_id THEN
    RAISE EXCEPTION 'Payment and installment belong to different Kuris.';
  END IF;

  INSERT INTO public.financial_idempotency_keys(
    actor_user_id,kuri_id,operation_type,idempotency_key,request_hash
  )
  VALUES(v_actor_user_id,target_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id
    AND f.operation_type='PAYMENT_ALLOCATION'
    AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different allocation request.';
  END IF;
  IF idem_row.status='COMPLETED' THEN
    RETURN idem_row.result_bigint;
  END IF;

  IF payment_person_id<>installment_person_id THEN
    RAISE EXCEPTION 'Payment person does not match installment person.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to allocate this payment.';
  END IF;

  IF payment_status<>'APPROVED' THEN
    RAISE EXCEPTION 'Only approved payments can be allocated.';
  END IF;

  SELECT coalesce(sum(pa.amount),0)
    INTO already_allocated
  FROM public.payment_allocations pa
  WHERE pa.payment_id=target_payment_id;

  SELECT coalesce(sum(pa.amount),0)
    INTO installment_allocated
  FROM public.payment_allocations pa
  WHERE pa.installment_id=target_installment_id;

  IF already_allocated+allocation_amount>payment_total THEN
    RAISE EXCEPTION 'Allocation exceeds payment amount.';
  END IF;

  IF installment_allocated+allocation_amount>installment_amount_due THEN
    RAISE EXCEPTION 'Allocation exceeds installment balance.';
  END IF;

  INSERT INTO public.payment_allocations(
    payment_id,installment_id,amount,allocated_by
  )
  VALUES(
    target_payment_id,target_installment_id,allocation_amount,
    (SELECT id FROM public.users WHERE id=v_actor_user_id)
  )
  ON CONFLICT(payment_id,installment_id)
  DO UPDATE SET
    amount=public.payment_allocations.amount+excluded.amount,
    allocated_at=now(),
    allocated_by=excluded.allocated_by;

  SELECT coalesce(sum(pa.amount),0)
    INTO installment_allocated
  FROM public.payment_allocations pa
  WHERE pa.installment_id=target_installment_id;

  next_paid:=least(installment_allocated,installment_amount_due);

  UPDATE public.installments
  SET amount_paid=next_paid,
      status=case
        when next_paid>=amount_due then 'PAID'::public.installment_status
        when next_paid>0 then 'PARTIAL'::public.installment_status
        else 'UNPAID'::public.installment_status
      end,
      updated_at=now()
  WHERE id=target_installment_id;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_bigint=next_paid,completed_at=now()
  WHERE id=idem_row.id;

  RETURN next_paid;
END $$;

REVOKE ALL ON FUNCTION public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint,text) TO authenticated;

COMMIT;
