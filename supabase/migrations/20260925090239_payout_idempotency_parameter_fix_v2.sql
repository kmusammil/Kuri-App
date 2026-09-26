BEGIN;

DROP FUNCTION IF EXISTS public.mark_payout_paid_for_admin(
  uuid,timestamptz,public.payment_method,text,text,text,bigint
);

CREATE FUNCTION public.mark_payout_paid_for_admin(
  target_winner_id uuid,
  payout_payment_date timestamptz,
  payout_method public.payment_method,
  p_idempotency_key text,
  payout_reference text DEFAULT NULL,
  payout_notes text DEFAULT NULL,
  payout_other_deductions bigint DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  v_actor_user_id uuid := (SELECT auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
  target_kuri_id uuid;
  payout_id uuid;
  payout_row public.payouts%rowtype;
  computed_net_amount bigint;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
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

  request_hash:=encode(
    extensions.digest(
      jsonb_build_array(target_winner_id::text,payout_payment_date,payout_method::text,
        payout_reference,payout_notes,payout_other_deductions::text)::text,
      'sha256'
    ),
    'hex'
  );

  INSERT INTO public.financial_idempotency_keys(
    actor_user_id,kuri_id,operation_type,idempotency_key,request_hash
  )
  VALUES(v_actor_user_id,target_kuri_id,'PAYOUT_PAYMENT',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id
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
      processed_by=(SELECT id FROM public.users WHERE id=v_actor_user_id),
      notes=nullif(btrim(payout_notes),'')
  WHERE id=payout_row.id;

  PERFORM public.transition_payout_status_for_admin(payout_row.id,'PAID');

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_payment_id=payout_row.id,completed_at=now()
  WHERE id=idem_row.id;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,text,bigint) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,text,bigint) TO authenticated;

COMMIT;