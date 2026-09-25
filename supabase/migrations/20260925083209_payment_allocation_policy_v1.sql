BEGIN;

CREATE OR REPLACE FUNCTION public.allocate_payment_for_admin(
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
  target_membership_id uuid;
  target_cycle_number integer;
  already_allocated bigint;
  installment_allocated bigint;
  next_paid bigint;
  earlier_outstanding bigint;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF allocation_amount<=0 THEN RAISE EXCEPTION 'Allocation amount must be greater than zero.'; END IF;

  request_hash:=encode(extensions.digest(jsonb_build_array(target_payment_id::text,target_installment_id::text,allocation_amount::text)::text,'sha256'),'hex');

  SELECT p.person_id,p.status,p.kuri_id INTO payment_person_id,payment_status,payment_kuri_id
  FROM public.payments p WHERE p.id=target_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;

  SELECT i.amount_due,m.person_id,m.id,c.kuri_id,c.cycle_number
    INTO installment_amount_due,installment_person_id,target_membership_id,target_kuri_id,target_cycle_number
  FROM public.installments i
  JOIN public.memberships m ON m.id=i.membership_id
  JOIN public.cycles c ON c.id=i.cycle_id
  WHERE i.id=target_installment_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Installment not found.'; END IF;
  IF payment_kuri_id<>target_kuri_id THEN RAISE EXCEPTION 'Payment and installment belong to different Kuris.'; END IF;

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor_user_id,target_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id AND f.operation_type='PAYMENT_ALLOCATION' AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN RAISE EXCEPTION 'Idempotency key was already used for a different allocation request.'; END IF;
  IF idem_row.status='COMPLETED' THEN RETURN idem_row.result_bigint; END IF;

  IF payment_person_id<>installment_person_id THEN RAISE EXCEPTION 'Payment person does not match installment person.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN RAISE EXCEPTION 'You do not have permission to allocate this payment.'; END IF;
  IF payment_status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be allocated.'; END IF;

  PERFORM 1
  FROM public.installments lock_i
  JOIN public.cycles lock_c ON lock_c.id=lock_i.cycle_id
  WHERE lock_i.membership_id=target_membership_id
  ORDER BY lock_c.cycle_number,lock_i.id
  FOR UPDATE;

  SELECT coalesce(sum(greatest(oi.amount_due-oi.effective_paid,0)),0)
    INTO earlier_outstanding
  FROM (
    SELECT oi.id,oi.amount_due,
      least(coalesce((
        SELECT sum(public.get_effective_payment_allocation_amount(pa.id))
        FROM public.payment_allocations pa WHERE pa.installment_id=oi.id
      ),0),oi.amount_due) AS effective_paid,
      oc.cycle_number
    FROM public.installments oi
    JOIN public.cycles oc ON oc.id=oi.cycle_id
    WHERE oi.membership_id=target_membership_id
  ) oi
  WHERE oi.cycle_number<target_cycle_number;

  IF earlier_outstanding>0 THEN
    RAISE EXCEPTION 'Cannot skip outstanding earlier installments. Allocate the oldest outstanding installment first.';
  END IF;

  payment_total:=public.get_effective_payment_amount(target_payment_id);

  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    INTO already_allocated
  FROM public.payment_allocations pa WHERE pa.payment_id=target_payment_id;

  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    INTO installment_allocated
  FROM public.payment_allocations pa WHERE pa.installment_id=target_installment_id;

  IF already_allocated+allocation_amount>payment_total THEN RAISE EXCEPTION 'Allocation exceeds payment amount.'; END IF;
  IF installment_allocated>=installment_amount_due THEN RAISE EXCEPTION 'Target installment is already fully paid.'; END IF;
  IF installment_allocated+allocation_amount>installment_amount_due THEN
    RAISE EXCEPTION 'Allocation exceeds installment balance. Use the advance-payment allocation API to span multiple installments.';
  END IF;

  INSERT INTO public.payment_allocations(payment_id,installment_id,amount,allocated_by)
  VALUES(target_payment_id,target_installment_id,allocation_amount,(SELECT id FROM public.users WHERE id=v_actor_user_id))
  ON CONFLICT(payment_id,installment_id)
  DO UPDATE SET amount=public.payment_allocations.amount+excluded.amount,allocated_at=now(),allocated_by=excluded.allocated_by;

  SELECT public.reconcile_installment_from_allocations(target_installment_id) INTO next_paid;

  UPDATE public.financial_idempotency_keys SET status='COMPLETED',result_bigint=next_paid,completed_at=now()
  WHERE id=idem_row.id;

  RETURN next_paid;
END;
$$;

CREATE FUNCTION public.allocate_payment_to_oldest_installments_for_admin(
  target_payment_id uuid,
  requested_allocation_amount bigint,
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
  payment_kuri_id uuid;
  payment_status public.payment_status;
  effective_payment_amount bigint;
  already_allocated bigint;
  available_payment bigint;
  total_outstanding bigint;
  remaining bigint;
  chunk bigint;
  installment_allocated bigint;
  effective_installment_paid bigint;
  actor_db_user_id uuid;
  i record;
  total_allocated bigint:=0;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF requested_allocation_amount<=0 THEN RAISE EXCEPTION 'Allocation amount must be greater than zero.'; END IF;

  request_hash:=encode(extensions.digest(jsonb_build_array(target_payment_id::text,requested_allocation_amount::text)::text,'sha256'),'hex');

  SELECT p.person_id,p.kuri_id,p.status INTO payment_person_id,payment_kuri_id,payment_status
  FROM public.payments p WHERE p.id=target_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;

  IF NOT public.has_kuri_admin_role(payment_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN RAISE EXCEPTION 'You do not have permission to allocate this payment.'; END IF;
  IF payment_status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be allocated.'; END IF;

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor_user_id,payment_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id AND f.operation_type='PAYMENT_ALLOCATION' AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN RAISE EXCEPTION 'Idempotency key was already used for a different allocation request.'; END IF;
  IF idem_row.status='COMPLETED' THEN RETURN idem_row.result_bigint; END IF;

  actor_db_user_id := (SELECT id FROM public.users WHERE id=v_actor_user_id);

  PERFORM 1
  FROM public.installments lock_i
  JOIN public.cycles lock_c ON lock_c.id=lock_i.cycle_id
  WHERE lock_i.membership_id IN (
    SELECT m.id FROM public.memberships m
    WHERE m.kuri_id=payment_kuri_id AND m.person_id=payment_person_id
  )
  ORDER BY lock_c.cycle_number,lock_i.id
  FOR UPDATE;

  effective_payment_amount:=public.get_effective_payment_amount(target_payment_id);

  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    INTO already_allocated
  FROM public.payment_allocations pa WHERE pa.payment_id=target_payment_id;

  available_payment:=greatest(effective_payment_amount-already_allocated,0);
  IF requested_allocation_amount>available_payment THEN
    RAISE EXCEPTION 'Allocation exceeds the payment amount available for allocation.';
  END IF;

  SELECT coalesce(sum(greatest(x.amount_due-x.effective_paid,0)),0)
    INTO total_outstanding
  FROM (
    SELECT oi.amount_due,
      least(coalesce((
        SELECT sum(public.get_effective_payment_allocation_amount(pa2.id))
        FROM public.payment_allocations pa2 WHERE pa2.installment_id=oi.id
      ),0),oi.amount_due) AS effective_paid
    FROM public.installments oi
    JOIN public.memberships om ON om.id=oi.membership_id
    JOIN public.cycles oc ON oc.id=oi.cycle_id
    WHERE om.kuri_id=payment_kuri_id AND om.person_id=payment_person_id
  ) x;

  IF requested_allocation_amount>total_outstanding THEN
    RAISE EXCEPTION 'Allocation exceeds the total outstanding installments for this membership.';
  END IF;

  remaining:=requested_allocation_amount;

  FOR i IN
    SELECT oi.id,oi.amount_due,oc.cycle_number
    FROM public.installments oi
    JOIN public.memberships om ON om.id=oi.membership_id
    JOIN public.cycles oc ON oc.id=oi.cycle_id
    WHERE om.kuri_id=payment_kuri_id AND om.person_id=payment_person_id
    ORDER BY oc.cycle_number,oi.id
  LOOP
    EXIT WHEN remaining=0;

    SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
      INTO installment_allocated
    FROM public.payment_allocations pa WHERE pa.installment_id=i.id;

    effective_installment_paid:=least(installment_allocated,i.amount_due);
    chunk:=least(remaining,greatest(i.amount_due-effective_installment_paid,0));

    IF chunk>0 THEN
      INSERT INTO public.payment_allocations(payment_id,installment_id,amount,allocated_by)
      VALUES(target_payment_id,i.id,chunk,actor_db_user_id)
      ON CONFLICT(payment_id,installment_id)
      DO UPDATE SET amount=public.payment_allocations.amount+excluded.amount,allocated_at=now(),allocated_by=excluded.allocated_by;

      PERFORM public.reconcile_installment_from_allocations(i.id);
      remaining:=remaining-chunk;
      total_allocated:=total_allocated+chunk;
    END IF;
  END LOOP;

  IF remaining<>0 THEN RAISE EXCEPTION 'Unable to allocate the complete requested amount.'; END IF;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_bigint=total_allocated,completed_at=now()
  WHERE id=idem_row.id;

  RETURN total_allocated;
END;
$$;

REVOKE ALL ON FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.allocate_payment_to_oldest_installments_for_admin(uuid,bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.allocate_payment_to_oldest_installments_for_admin(uuid,bigint,text) TO authenticated;

COMMIT;