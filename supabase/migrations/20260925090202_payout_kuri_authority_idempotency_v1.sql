BEGIN;

CREATE OR REPLACE FUNCTION public.transition_payout_status_for_admin(
  target_payout_id uuid,
  target_status public.payout_status
)
RETURNS public.payout_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  current_status public.payout_status;
  target_kuri_id uuid;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT p.status,k.id
    INTO current_status,target_kuri_id
  FROM public.payouts p
  JOIN public.monthly_winners mw ON mw.id=p.monthly_winner_id
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE p.id=target_payout_id
  FOR UPDATE OF p,k;

  IF target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Payout not found.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to change this payout status.';
  END IF;

  IF current_status=target_status THEN
    RETURN current_status;
  END IF;

  IF NOT (
    (current_status='PENDING' AND target_status IN ('PROCESSING','CANCELLED'))
    OR (current_status='PROCESSING' AND target_status IN ('PAID','CANCELLED'))
  ) THEN
    RAISE EXCEPTION 'Invalid payout status transition: % -> %.',current_status,target_status;
  END IF;

  UPDATE public.payouts SET status=target_status WHERE id=target_payout_id;
  RETURN target_status;
END;
$$;

CREATE OR REPLACE FUNCTION public.prepare_payout_for_admin(target_winner_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  payout_id uuid;
  winner_person_id uuid;
  winner_cycle_id uuid;
  target_kuri_id uuid;
  gross_amount bigint;
  configured_muppu_amount bigint;
  deducted_muppu_amount bigint;
  payout_muppu_amount bigint;
  cycle_status_value public.cycle_status;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT mw.person_id,mw.cycle_id,k.id,k.gross_prize_amount,k.muppu_amount,c.status
    INTO winner_person_id,winner_cycle_id,target_kuri_id,gross_amount,
         configured_muppu_amount,cycle_status_value
  FROM public.monthly_winners mw
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  FOR UPDATE OF mw,k,c;

  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Monthly winner not found.'; END IF;
  IF cycle_status_value<>'COMPLETED' THEN RAISE EXCEPTION 'Cycle must be COMPLETED before preparing a payout.'; END IF;
  IF gross_amount<=0 THEN RAISE EXCEPTION 'Gross prize amount must be greater than zero.'; END IF;

  SELECT coalesce(sum(mr.amount),0)
    INTO deducted_muppu_amount
  FROM public.muppu_records mr
  WHERE mr.person_id=winner_person_id
    AND mr.cycle_id=winner_cycle_id
    AND mr.status='DEDUCTED';

  payout_muppu_amount:=greatest(coalesce(configured_muppu_amount,0),deducted_muppu_amount);

  INSERT INTO public.payouts(monthly_winner_id,gross_amount,muppu_amount,other_deductions,net_amount,status)
  VALUES(target_winner_id,gross_amount,payout_muppu_amount,0,greatest(gross_amount-payout_muppu_amount,0),'PENDING')
  ON CONFLICT(monthly_winner_id)
  DO UPDATE SET
    gross_amount=excluded.gross_amount,
    muppu_amount=excluded.muppu_amount,
    net_amount=greatest(excluded.gross_amount-excluded.muppu_amount-public.payouts.other_deductions,0)
  WHERE public.payouts.status='PENDING'
  RETURNING id INTO payout_id;

  IF payout_id IS NULL THEN
    SELECT po.id INTO payout_id
    FROM public.payouts po
    WHERE po.monthly_winner_id=target_winner_id
    FOR UPDATE;
  END IF;

  RETURN payout_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_payout_for_admin(target_winner_id uuid)
RETURNS TABLE(
  payout_id uuid,winner_id uuid,person_id uuid,registered_name text,display_name text,
  gross_amount bigint,muppu_amount bigint,other_deductions bigint,net_amount bigint,
  payment_date timestamptz,method public.payment_method,reference_number text,
  status public.payout_status,processed_by uuid,notes text,created_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT po.id,mw.id,mw.person_id,p.registered_name,p.display_name,
         po.gross_amount,po.muppu_amount,po.other_deductions,po.net_amount,
         po.payment_date,po.method,po.reference_number,po.status,po.processed_by,po.notes,po.created_at
  FROM public.payouts po
  JOIN public.monthly_winners mw ON mw.id=po.monthly_winner_id
  JOIN public.people p ON p.id=mw.person_id
  JOIN public.cycles c ON c.id=mw.cycle_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$$;

CREATE OR REPLACE FUNCTION public.list_payouts_for_admin(target_kuri_id uuid DEFAULT NULL)
RETURNS TABLE(
  payout_id uuid,winner_id uuid,cycle_number integer,person_id uuid,
  registered_name text,display_name text,gross_amount bigint,muppu_amount bigint,
  other_deductions bigint,net_amount bigint,payment_date timestamptz,
  method public.payment_method,reference_number text,status public.payout_status
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT po.id,mw.id,c.cycle_number,mw.person_id,p.registered_name,p.display_name,
         po.gross_amount,po.muppu_amount,po.other_deductions,po.net_amount,
         po.payment_date,po.method,po.reference_number,po.status
  FROM public.payouts po
  JOIN public.monthly_winners mw ON mw.id=po.monthly_winner_id
  JOIN public.people p ON p.id=mw.person_id
  JOIN public.cycles c ON c.id=mw.cycle_id
  WHERE (target_kuri_id IS NULL OR c.kuri_id=target_kuri_id)
    AND public.has_kuri_admin_role(c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY c.cycle_number DESC,po.created_at DESC;
$$;

DROP FUNCTION IF EXISTS public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,bigint);

CREATE FUNCTION public.mark_payout_paid_for_admin(
  target_winner_id uuid,
  payout_payment_date timestamptz,
  payout_method public.payment_method,
  p_idempotency_key text,
  payout_reference text DEFAULT NULL,
  payout_notes text DEFAULT NULL,
  payout_other_deductions bigint DEFAULT 0
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  actor_user_id uuid := (SELECT auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
  target_kuri_id uuid;
  payout_id uuid;
  payout_row public.payouts%rowtype;
  computed_net_amount bigint;
BEGIN
  IF actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF payout_other_deductions<0 THEN RAISE EXCEPTION 'Other deductions cannot be negative.'; END IF;

  SELECT k.id INTO target_kuri_id
  FROM public.monthly_winners mw
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  FOR UPDATE OF mw,k,c;

  IF target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Monthly winner not found or you do not have permission to process this payout.';
  END IF;

  request_hash:=encode(extensions.digest(
    jsonb_build_array(target_winner_id::text,payout_payment_date,payout_method::text,
      payout_reference,payout_notes,payout_other_deductions::text)::text,
    'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(actor_user_id,target_kuri_id,'PAYOUT_PAYMENT',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=actor_user_id
    AND f.operation_type='PAYOUT_PAYMENT'
    AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different payout request.';
  END IF;
  IF idem_row.status='COMPLETED' THEN RETURN; END IF;

  payout_id:=public.prepare_payout_for_admin(target_winner_id);

  SELECT po.* INTO payout_row FROM public.payouts po WHERE po.id=payout_id FOR UPDATE;
  IF payout_row.id IS NULL THEN RAISE EXCEPTION 'Payout not found.'; END IF;
  IF payout_row.status<>'PENDING' THEN RAISE EXCEPTION 'Only a PENDING payout can be marked PAID.'; END IF;

  PERFORM public.transition_payout_status_for_admin(payout_row.id,'PROCESSING');

  computed_net_amount:=greatest(payout_row.gross_amount-payout_row.muppu_amount-payout_other_deductions,0);

  UPDATE public.payouts
  SET other_deductions=payout_other_deductions,
      net_amount=computed_net_amount,
      payment_date=coalesce(payout_payment_date,now()),
      method=payout_method,
      reference_number=nullif(btrim(payout_reference),''),
      processed_by=(SELECT id FROM public.users WHERE id=actor_user_id),
      notes=nullif(btrim(payout_notes),'')
  WHERE id=payout_row.id;

  PERFORM public.transition_payout_status_for_admin(payout_row.id,'PAID');

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_payment_id=payout_row.id,completed_at=now()
  WHERE id=idem_row.id;
END;
$$;

REVOKE ALL ON FUNCTION public.transition_payout_status_for_admin(uuid,public.payout_status) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.prepare_payout_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_payout_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_payouts_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,text,bigint) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.transition_payout_status_for_admin(uuid,public.payout_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.prepare_payout_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_payout_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_payouts_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,text,bigint) TO authenticated;

COMMIT;