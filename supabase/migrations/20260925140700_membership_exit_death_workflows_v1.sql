-- Production reconciliation: final hardened exit/death workflow functions.
CREATE OR REPLACE FUNCTION public.transition_membership_exit_status_for_admin(target_exit_id uuid, target_status settlement_status)
 RETURNS settlement_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_status public.settlement_status; v_kuri_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT me.status,m.kuri_id INTO v_status,v_kuri_id
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id FOR UPDATE;
  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Membership exit not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to change this exit status.';
  END IF;
  IF v_status=target_status THEN RETURN v_status; END IF;
  IF NOT (
    (v_status='PENDING' AND target_status IN ('APPROVED','CANCELLED'))
    OR (v_status='APPROVED' AND target_status IN ('SETTLED','CANCELLED'))
  ) THEN
    RAISE EXCEPTION 'Invalid membership exit transition: % -> %.',v_status,target_status;
  END IF;
  UPDATE public.membership_exits
  SET status=target_status,
      settled_at=CASE WHEN target_status='SETTLED' THEN coalesce(settled_at,now()) ELSE settled_at END
  WHERE id=target_exit_id;
  RETURN target_status;
END
$function$;

CREATE OR REPLACE FUNCTION public.get_membership_exit_settlement_context_for_admin(target_exit_id uuid)
 RETURNS TABLE(exit_id uuid, membership_id uuid, kuri_id uuid, membership_number text, original_person_id uuid, current_holder_person_id uuid, reason settlement_reason, refund_policy refund_policy, requested_at timestamp with time zone, death_date date, death_date_verified_at timestamp with time zone, amount_contributed bigint, unallocated_payment_amount bigint, outstanding_installment_amount bigint, unpaid_expense_amount bigint, unpaid_muppu_amount bigint, pending_prize_amount bigint, has_prior_win boolean, settlement_amount bigint, status settlement_status)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT me.id,f.membership_id,f.kuri_id,f.membership_number,f.original_person_id,
         f.current_holder_person_id,me.reason,me.refund_policy,me.requested_at,
         CASE WHEN me.reason='DEATH' THEN me.exit_date ELSE NULL END,me.death_date_verified_at,
         f.contributed_amount,f.unallocated_payment_amount,f.outstanding_installment_amount,
         f.unpaid_expense_amount,f.unpaid_muppu_amount,f.pending_prize_amount,f.has_prior_win,
         f.settlement_amount,me.status
  FROM public.membership_exits me
  JOIN LATERAL public.calculate_membership_exit_financials(me.id) f ON true
  WHERE me.id=target_exit_id
    AND public.has_kuri_admin_role(f.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

CREATE OR REPLACE FUNCTION public.refresh_membership_exit_financials_for_admin(target_exit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_kuri_id uuid; v_status public.settlement_status; v_contributed bigint; v_settlement bigint;
BEGIN
  SELECT m.kuri_id,me.status INTO v_kuri_id,v_status
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id FOR UPDATE;
  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to refresh this exit settlement.';
  END IF;
  IF v_status IN ('SETTLED','CANCELLED') THEN RETURN; END IF;
  SELECT contributed_amount,settlement_amount INTO v_contributed,v_settlement
  FROM public.calculate_membership_exit_financials(target_exit_id);
  UPDATE public.membership_exits
  SET amount_contributed=greatest(coalesce(v_contributed,0),0),
      refund_amount=greatest(coalesce(v_settlement,0),0)
  WHERE id=target_exit_id AND status IN ('PENDING','APPROVED');
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_membership_exit_for_admin(target_membership_id uuid, exit_reason settlement_reason, target_exit_date date, target_refund_policy refund_policy DEFAULT 'AT_MATURITY'::refund_policy, target_refund_amount bigint DEFAULT NULL::bigint, target_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_kuri_id uuid;
  v_membership_status public.membership_status;
  v_exit_id uuid;
  v_idem public.financial_idempotency_keys%rowtype;
  v_hash text;
  v_key text:=nullif(btrim(p_idempotency_key),'');
  v_contributed bigint;
  v_settlement bigint;
  v_refund bigint;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF v_key IS NULL OR char_length(v_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF target_exit_date IS NULL OR target_exit_date>current_date THEN RAISE EXCEPTION 'Exit date must not be in the future.'; END IF;
  IF target_refund_amount IS NOT NULL AND target_refund_amount<0 THEN RAISE EXCEPTION 'Refund amount cannot be negative.'; END IF;

  SELECT m.kuri_id,m.status INTO v_kuri_id,v_membership_status
  FROM public.memberships m WHERE m.id=target_membership_id FOR UPDATE;
  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Membership not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to create an exit for this Kuri.';
  END IF;
  IF v_membership_status NOT IN ('ACTIVE','SUSPENDED') THEN
    RAISE EXCEPTION 'Only ACTIVE or SUSPENDED memberships can request an exit.';
  END IF;

  v_hash:=encode(extensions.digest(jsonb_build_array(
    target_membership_id::text,exit_reason::text,target_exit_date::text,target_refund_policy::text,
    coalesce(target_refund_amount,-1)::text,coalesce(btrim(target_notes),'')
  )::text,'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor,v_kuri_id,'EXIT_CREATE',v_key,v_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT * INTO v_idem FROM public.financial_idempotency_keys
  WHERE actor_user_id=v_actor AND operation_type='EXIT_CREATE' AND idempotency_key=v_key FOR UPDATE;

  IF v_idem.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key was already used for a different exit request.'; END IF;
  IF v_idem.status='COMPLETED' THEN RETURN v_idem.result_reference_id; END IF;

  IF EXISTS (
    SELECT 1 FROM public.membership_exits me
    WHERE me.membership_id=target_membership_id AND me.status NOT IN ('CANCELLED','SETTLED')
  ) THEN RAISE EXCEPTION 'A non-terminal exit request already exists for this membership.'; END IF;

  INSERT INTO public.membership_exits(
    membership_id,reason,exit_date,refund_policy,amount_contributed,refund_amount,status,requested_at,notes
  ) VALUES(
    target_membership_id,exit_reason,target_exit_date,target_refund_policy,0,0,'PENDING',now(),
    nullif(btrim(target_notes),'')
  ) RETURNING id INTO v_exit_id;

  SELECT contributed_amount,settlement_amount INTO v_contributed,v_settlement
  FROM public.calculate_membership_exit_financials(v_exit_id);

  v_refund:=CASE
    WHEN target_refund_amount IS NULL THEN greatest(v_settlement,0)
    ELSE least(greatest(target_refund_amount,0),greatest(v_settlement,0))
  END;

  UPDATE public.membership_exits
  SET amount_contributed=greatest(v_contributed,0),refund_amount=v_refund
  WHERE id=v_exit_id;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_reference_id=v_exit_id,completed_at=now()
  WHERE id=v_idem.id;

  RETURN v_exit_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.verify_death_date_for_admin(target_exit_id uuid, verified_death_date date, verification_notes text DEFAULT NULL::text)
 RETURNS date
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_actor uuid:=(SELECT auth.uid()); v_kuri_id uuid; v_exit_date date;
  v_reason public.settlement_reason; v_status public.settlement_status;
  v_existing date;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF verified_death_date IS NULL OR verified_death_date>current_date THEN
    RAISE EXCEPTION 'Verified death date must not be in the future.';
  END IF;

  SELECT m.kuri_id,me.exit_date,me.reason,me.status,me.death_date
    INTO v_kuri_id,v_exit_date,v_reason,v_status,v_existing
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id FOR UPDATE;

  IF v_kuri_id IS NULL OR v_reason<>'DEATH' THEN RAISE EXCEPTION 'Death exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to verify this death case.';
  END IF;
  IF v_status NOT IN ('PENDING','APPROVED') THEN RAISE EXCEPTION 'Death date cannot be verified for this exit state.'; END IF;
  IF verified_death_date>v_exit_date THEN RAISE EXCEPTION 'Death date cannot be after the exit date.'; END IF;
  IF v_existing IS NOT NULL AND v_existing<>verified_death_date THEN
    RAISE EXCEPTION 'Verified death date is immutable once recorded.';
  END IF;

  UPDATE public.membership_exits
  SET death_date=verified_death_date,
      death_date_verified_at=coalesce(death_date_verified_at,now()),
      death_date_verified_by=coalesce(death_date_verified_by,(SELECT id FROM public.users WHERE id=v_actor)),
      notes=case
        when nullif(btrim(verification_notes),'') is null then notes
        when notes is null then 'Death date verification: '||btrim(verification_notes)
        else notes||' | Death date verification: '||btrim(verification_notes)
      end
  WHERE id=target_exit_id;

  RETURN verified_death_date;
END
$function$;

CREATE OR REPLACE FUNCTION public.approve_membership_exit_for_admin(target_exit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_kuri_id uuid; v_membership_id uuid; v_status public.settlement_status; v_contributed bigint:=0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT m.kuri_id,me.membership_id,me.status INTO v_kuri_id,v_membership_id,v_status
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id FOR UPDATE;
  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to approve this exit.';
  END IF;
  IF v_status='APPROVED' THEN RETURN; END IF;
  IF v_status<>'PENDING' THEN RAISE EXCEPTION 'Exit is not pending approval.'; END IF;

  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) INTO v_contributed
  FROM public.payment_allocations pa JOIN public.payments pay ON pay.id=pa.payment_id
  JOIN public.installments i ON i.id=pa.installment_id
  WHERE i.membership_id=v_membership_id AND pay.status='APPROVED' AND pay.kuri_id=v_kuri_id;

  UPDATE public.membership_exits
  SET amount_contributed=v_contributed,refund_amount=least(coalesce(refund_amount,0),v_contributed),
      approved_by=(SELECT id FROM public.users WHERE id=auth.uid())
  WHERE id=target_exit_id AND status='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'Exit is no longer pending.'; END IF;
  PERFORM public.transition_membership_exit_status_for_admin(target_exit_id,'APPROVED');
END
$function$;

CREATE OR REPLACE FUNCTION public.cancel_membership_exit_for_admin(target_exit_id uuid, cancellation_reason text DEFAULT NULL::text)
 RETURNS settlement_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid:=auth.uid(); v_kuri_id uuid; v_status public.settlement_status; v_reason public.settlement_reason;
  v_paid bigint; v_hash text; v_key text; v_idem public.financial_idempotency_keys%rowtype;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT m.kuri_id,me.status,me.reason INTO v_kuri_id,v_status,v_reason
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id FOR UPDATE;
  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to cancel this exit.';
  END IF;

  v_hash:=encode(extensions.digest(jsonb_build_array(
    target_exit_id::text,coalesce(btrim(cancellation_reason),'')
  )::text,'sha256'),'hex');
  v_key:='AUTO-EXIT-CANCEL-'||v_hash;
  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor,v_kuri_id,'EXIT_CANCEL',v_key,v_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;
  SELECT * INTO v_idem FROM public.financial_idempotency_keys
  WHERE actor_user_id=v_actor AND operation_type='EXIT_CANCEL' AND idempotency_key=v_key FOR UPDATE;
  IF v_idem.request_hash<>v_hash THEN RAISE EXCEPTION 'Exit cancellation replay hash mismatch.'; END IF;
  IF v_idem.status='COMPLETED' THEN RETURN 'CANCELLED'; END IF;
  IF v_status='CANCELLED' THEN
    UPDATE public.financial_idempotency_keys SET status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
    WHERE id=v_idem.id; RETURN 'CANCELLED';
  END IF;
  IF v_status='SETTLED' THEN RAISE EXCEPTION 'Settled exits are terminal and cannot be cancelled.'; END IF;
  IF v_status='APPROVED' AND v_reason='DEATH' THEN
    RAISE EXCEPTION 'Approved death exits cannot be cancelled through the ordinary exit-cancellation action.';
  END IF;

  SELECT coalesce(sum(rt.amount),0) INTO v_paid
  FROM public.membership_exit_refund_transactions rt WHERE rt.membership_exit_id=target_exit_id;
  IF v_paid>0 THEN RAISE EXCEPTION 'An exit with an executed refund cannot be cancelled.'; END IF;

  UPDATE public.membership_exits
  SET status='CANCELLED',
      notes=case
        when nullif(btrim(cancellation_reason),'') is null then notes
        when notes is null then 'Cancelled: '||btrim(cancellation_reason)
        else notes||' | Cancelled: '||btrim(cancellation_reason)
      end
  WHERE id=target_exit_id AND status IN ('PENDING','APPROVED');

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
  WHERE id=v_idem.id;
  RETURN 'CANCELLED';
END;
$function$;

CREATE OR REPLACE FUNCTION public.settle_membership_exit_for_admin(target_exit_id uuid, settlement_payment_method muppu_settlement_method DEFAULT 'PAID_IN_ADVANCE'::muppu_settlement_method, settlement_reference text DEFAULT NULL::text, settlement_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_idempotency_key text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_kuri_id uuid;
  v_membership_id uuid;
  v_status public.settlement_status;
  v_reason public.settlement_reason;
  v_policy public.refund_policy;
  v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text;
  v_idem public.financial_idempotency_keys%rowtype;
  v_contributed bigint;
  v_settlement bigint;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF v_key IS NULL OR char_length(v_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;

  SELECT m.kuri_id,me.membership_id,me.status,me.reason,me.refund_policy
    INTO v_kuri_id,v_membership_id,v_status,v_reason,v_policy
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id FOR UPDATE OF me,m;

  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to settle this exit.';
  END IF;

  v_hash:=encode(extensions.digest(jsonb_build_array(
    target_exit_id::text,settlement_payment_method::text,coalesce(btrim(settlement_reference),''),
    coalesce(settlement_date::text,'')
  )::text,'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor,v_kuri_id,'EXIT_SETTLE',v_key,v_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT * INTO v_idem FROM public.financial_idempotency_keys
  WHERE actor_user_id=v_actor AND operation_type='EXIT_SETTLE' AND idempotency_key=v_key FOR UPDATE;

  IF v_idem.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key was already used for a different exit settlement.'; END IF;
  IF v_idem.status='COMPLETED' THEN RETURN; END IF;

  IF v_status='SETTLED' THEN
    UPDATE public.financial_idempotency_keys SET status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
    WHERE id=v_idem.id;
    RETURN;
  END IF;

  IF v_status<>'APPROVED' THEN RAISE EXCEPTION 'Exit must be approved before settlement.'; END IF;
  IF v_reason='DEATH' AND NOT EXISTS (
    SELECT 1 FROM public.membership_exits WHERE id=target_exit_id AND death_date_verified_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'Verify the death date before settling the death case.'; END IF;
  IF settlement_payment_method='PAID_IN_ADVANCE' THEN
    RAISE EXCEPTION 'Use the refund payment action to record an immediate refund.';
  END IF;
  IF v_policy='IMMEDIATE' THEN
    RAISE EXCEPTION 'Immediate refunds must be settled through the refund transaction action.';
  END IF;

  SELECT contributed_amount,settlement_amount INTO v_contributed,v_settlement
  FROM public.calculate_membership_exit_financials(target_exit_id);

  UPDATE public.membership_exits
  SET amount_contributed=greatest(v_contributed,0),
      refund_amount=greatest(v_settlement,0),
      settled_at=coalesce(settlement_date,now()),
      notes=concat_ws(' | ',notes,'Settled without immediate cash refund: '||coalesce(btrim(settlement_reference),'')),
      status='SETTLED'
  WHERE id=target_exit_id AND status='APPROVED';

  UPDATE public.memberships
  SET status='EXITED',exited_at=coalesce(exited_at,coalesce(settlement_date,now()))
  WHERE id=v_membership_id;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
  WHERE id=v_idem.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_membership_exit_refund_for_admin(target_exit_id uuid, refund_amount bigint, refund_payment_method payment_method, refund_reference text DEFAULT NULL::text, refund_paid_at timestamp with time zone DEFAULT NULL::timestamp with time zone, refund_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_kuri_id uuid;
  v_membership_id uuid;
  v_status public.settlement_status;
  v_policy public.refund_policy;
  v_expected bigint;
  v_paid bigint;
  v_balance bigint;
  v_tx_id uuid;
  v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text;
  v_idem public.financial_idempotency_keys%rowtype;
  v_contributed bigint;
  v_settlement bigint;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF v_key IS NULL OR char_length(v_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF refund_amount<=0 THEN RAISE EXCEPTION 'Refund amount must be greater than zero.'; END IF;

  SELECT m.kuri_id,me.membership_id,me.status,me.refund_policy
    INTO v_kuri_id,v_membership_id,v_status,v_policy
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id FOR UPDATE OF me,m;

  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to record this refund.';
  END IF;

  v_hash:=encode(extensions.digest(jsonb_build_array(
    target_exit_id::text,refund_amount::text,refund_payment_method::text,
    coalesce(btrim(refund_reference),''),coalesce(refund_paid_at::text,''),coalesce(btrim(refund_notes),'')
  )::text,'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor,v_kuri_id,'EXIT_REFUND',v_key,v_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT * INTO v_idem FROM public.financial_idempotency_keys
  WHERE actor_user_id=v_actor AND operation_type='EXIT_REFUND' AND idempotency_key=v_key FOR UPDATE;

  IF v_idem.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key was already used for a different refund request.'; END IF;
  IF v_idem.status='COMPLETED' THEN RETURN v_idem.result_reference_id; END IF;

  IF v_status<>'APPROVED' OR v_policy<>'IMMEDIATE' THEN
    RAISE EXCEPTION 'Only approved immediate refunds can be paid here.';
  END IF;

  SELECT contributed_amount,settlement_amount INTO v_contributed,v_settlement
  FROM public.calculate_membership_exit_financials(target_exit_id);
  v_expected:=greatest(v_settlement,0);

  SELECT coalesce(sum(rt.amount),0) INTO v_paid
  FROM public.membership_exit_refund_transactions rt WHERE rt.membership_exit_id=target_exit_id;
  v_balance:=greatest(v_expected-v_paid,0);

  IF v_balance<=0 THEN RAISE EXCEPTION 'No refund balance remains for this exit.'; END IF;
  IF refund_amount>v_balance THEN RAISE EXCEPTION 'Refund exceeds the remaining approved refund balance.'; END IF;

  INSERT INTO public.membership_exit_refund_transactions(
    membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
  )
  VALUES(
    target_exit_id,refund_amount,refund_payment_method,nullif(btrim(refund_reference),''),
    coalesce(refund_paid_at,now()),(SELECT id FROM public.users WHERE id=v_actor),nullif(btrim(refund_notes),'')
  )
  RETURNING id INTO v_tx_id;

  SELECT coalesce(sum(rt.amount),0) INTO v_paid
  FROM public.membership_exit_refund_transactions rt WHERE rt.membership_exit_id=target_exit_id;

  UPDATE public.membership_exits
  SET amount_contributed=greatest(v_contributed,0),refund_amount=v_expected,
      settled_at=CASE WHEN v_paid>=v_expected THEN now() ELSE settled_at END,
      status=CASE WHEN v_paid>=v_expected THEN 'SETTLED' ELSE 'APPROVED' END
  WHERE id=target_exit_id AND status='APPROVED';

  IF v_paid>=v_expected THEN
    UPDATE public.memberships
    SET status='EXITED',exited_at=coalesce(exited_at,now()) WHERE id=v_membership_id;
  END IF;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_reference_id=v_tx_id,completed_at=now()
  WHERE id=v_idem.id;
  RETURN v_tx_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.record_death_settlement_for_admin(target_exit_id uuid, target_nominee_id uuid DEFAULT NULL::uuid, p_settlement_notes text DEFAULT NULL::text, p_idempotency_key text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_kuri_id uuid;
  v_membership_id uuid;
  v_person_id uuid;
  v_status public.settlement_status;
  v_paid bigint;
  v_refund bigint;
  v_remaining bigint;
  v_nominee_name text;
  v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text;
  v_idem public.financial_idempotency_keys%rowtype;
  v_contributed bigint;
  v_settlement bigint;
  v_notes text:=nullif(btrim(record_death_settlement_for_admin.p_settlement_notes),'');
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF v_key IS NULL OR char_length(v_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;

  SELECT m.kuri_id,m.id,m.person_id,me.status INTO v_kuri_id,v_membership_id,v_person_id,v_status
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id AND me.reason='DEATH' FOR UPDATE OF me,m;

  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Death exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to settle this death case.';
  END IF;

  v_hash:=encode(extensions.digest(jsonb_build_array(
    target_exit_id::text,target_nominee_id::text,coalesce(v_notes,'')
  )::text,'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor,v_kuri_id,'DEATH_SETTLEMENT',v_key,v_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT * INTO v_idem FROM public.financial_idempotency_keys
  WHERE actor_user_id=v_actor AND operation_type='DEATH_SETTLEMENT' AND idempotency_key=v_key FOR UPDATE;

  IF v_idem.request_hash<>v_hash THEN RAISE EXCEPTION 'Idempotency key was already used for a different death settlement.'; END IF;
  IF v_idem.status='COMPLETED' THEN RETURN; END IF;
  IF v_status='SETTLED' THEN
    UPDATE public.financial_idempotency_keys SET status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
    WHERE id=v_idem.id; RETURN;
  END IF;

  IF v_status<>'APPROVED' THEN RAISE EXCEPTION 'Death exit must be approved before settlement.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.membership_exits WHERE id=target_exit_id AND death_date_verified_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'Verify the death date before settling the death case.'; END IF;
  IF target_nominee_id IS NULL THEN RAISE EXCEPTION 'A nominee must be selected before settlement.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.nominees n WHERE n.id=target_nominee_id AND n.person_id=v_person_id
  ) THEN RAISE EXCEPTION 'Selected nominee does not belong to this person.'; END IF;

  SELECT contributed_amount,settlement_amount INTO v_contributed,v_settlement
  FROM public.calculate_membership_exit_financials(target_exit_id);
  v_refund:=greatest(v_settlement,0);

  SELECT coalesce(sum(rt.amount),0) INTO v_paid
  FROM public.membership_exit_refund_transactions rt WHERE rt.membership_exit_id=target_exit_id;
  v_remaining:=greatest(v_refund-v_paid,0);

  SELECT n.name INTO v_nominee_name FROM public.nominees n WHERE n.id=target_nominee_id;

  IF v_remaining>0 THEN
    INSERT INTO public.membership_exit_refund_transactions(
      membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
    )
    VALUES(
      target_exit_id,v_remaining,'OTHER',null,now(),(SELECT id FROM public.users WHERE id=v_actor),
      'Death settlement refund to nominee: '||coalesce(v_nominee_name,'Nominee')
    );
  END IF;

  UPDATE public.membership_exits
  SET amount_contributed=greatest(v_contributed,0),refund_amount=v_refund,
      settled_to_nominee_id=target_nominee_id,settlement_notes=v_notes,settled_at=now(),status='SETTLED'
  WHERE id=target_exit_id AND status='APPROVED';

  UPDATE public.memberships
  SET status='EXITED',exited_at=coalesce(exited_at,now()) WHERE id=v_membership_id;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
  WHERE id=v_idem.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_membership_exit_reconciliation_for_admin(target_exit_id uuid)
 RETURNS TABLE(exit_id uuid, membership_id uuid, kuri_id uuid, kuri_name text, membership_number text, registered_name text, display_name text, reason settlement_reason, refund_policy refund_policy, amount_contributed bigint, refund_amount bigint, exit_status settlement_status, paid_refund_amount bigint, refund_balance bigint, refund_payment_id uuid, refund_payment_method payment_method, refund_payment_reference text, refund_paid_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT me.id,m.id,k.id,k.name,m.membership_number,p.registered_name,p.display_name,
         me.reason,me.refund_policy,me.amount_contributed,me.refund_amount,me.status,
         coalesce(rt.amount,0),greatest(me.refund_amount-coalesce(rt.amount,0),0),
         rt.id,rt.payment_method,rt.payment_reference,rt.paid_at
  FROM public.membership_exits me
  JOIN public.memberships m ON m.id=me.membership_id
  JOIN public.kuris k ON k.id=m.kuri_id
  JOIN public.people p ON p.id=m.person_id
  LEFT JOIN public.membership_exit_refund_transactions rt ON rt.membership_exit_id=me.id
  WHERE me.id=target_exit_id
    AND public.has_kuri_admin_role(m.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

CREATE OR REPLACE FUNCTION public.get_death_settlement_context_for_admin(target_membership_id uuid)
 RETURNS TABLE(membership_id uuid, membership_number text, person_id uuid, registered_name text, display_name text, nominee_id uuid, nominee_name text, nominee_relationship text, nominee_phone text, nominee_address text, nominee_notes text, refund_policy refund_policy, amount_contributed bigint, refund_amount bigint, exit_status settlement_status, exit_date date, settled_to_nominee_id uuid, settlement_notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
         n.id,n.name,n.relationship,n.phone,n.address,n.notes,
         me.refund_policy,me.amount_contributed,me.refund_amount,me.status,
         me.exit_date,me.settled_to_nominee_id,me.settlement_notes
  FROM public.memberships m
  JOIN public.people p ON p.id=m.person_id
  JOIN public.membership_exits me ON me.membership_id=m.id
  LEFT JOIN public.nominees n ON n.person_id=m.person_id
    AND (me.settled_to_nominee_id IS NULL OR n.id=me.settled_to_nominee_id)
  WHERE m.id=target_membership_id AND me.reason='DEATH' AND me.status<>'CANCELLED'
    AND public.has_kuri_admin_role(m.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY n.name,n.id;
$function$;

CREATE OR REPLACE FUNCTION public.get_membership_exit_membership_id_for_admin(target_exit_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT me.membership_id
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id
    AND public.has_kuri_admin_role(m.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

CREATE OR REPLACE FUNCTION public.get_membership_nominees_for_admin(target_membership_id uuid)
 RETURNS TABLE(membership_id uuid, membership_number text, person_id uuid, registered_name text, display_name text, nominee_id uuid, nominee_name text, nominee_relationship text, nominee_phone text, nominee_address text, nominee_notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
         n.id,n.name,n.relationship,n.phone,n.address,n.notes
  FROM public.memberships m JOIN public.people p ON p.id=m.person_id
  LEFT JOIN public.nominees n ON n.person_id=m.person_id
  WHERE m.id=target_membership_id
    AND public.has_kuri_admin_role(m.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY n.name,n.id;
$function$;

REVOKE ALL ON FUNCTION public.transition_membership_exit_status_for_admin(uuid,public.settlement_status) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.get_membership_exit_settlement_context_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.refresh_membership_exit_financials_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.approve_membership_exit_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.verify_death_date_for_admin(uuid,date,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.cancel_membership_exit_for_admin(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.record_death_settlement_for_admin(uuid,uuid,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_membership_exit_reconciliation_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_death_settlement_context_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_membership_exit_membership_id_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_membership_nominees_for_admin(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_membership_exit_settlement_context_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_membership_exit_financials_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_membership_exit_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_death_date_for_admin(uuid,date,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_membership_exit_for_admin(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_death_settlement_for_admin(uuid,uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_membership_exit_reconciliation_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_death_settlement_context_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_membership_exit_membership_id_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_membership_nominees_for_admin(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.calculate_membership_exit_financials(uuid) FROM PUBLIC,anon,authenticated;
