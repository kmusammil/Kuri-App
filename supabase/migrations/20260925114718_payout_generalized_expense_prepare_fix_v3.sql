BEGIN;

CREATE OR REPLACE FUNCTION public.prepare_payout_for_admin(target_winner_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='public'
AS $function$
DECLARE
  v_actor_user_id uuid := auth.uid();
  v_payout_id uuid;
  v_payout_status public.payout_status;
  v_winner_person_id uuid;
  v_winner_cycle_id uuid;
  v_target_kuri_id uuid;
  v_gross_prize_amount bigint;
  v_configured_muppu_amount bigint;
  v_deducted_muppu_amount bigint;
  v_payout_muppu_amount bigint;
  v_expense_deduction_amount bigint := 0;
  v_cycle_status public.cycle_status;
BEGIN
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT
    mw.person_id,mw.cycle_id,k.id,k.gross_prize_amount,k.muppu_amount,c.status
  INTO
    v_winner_person_id,v_winner_cycle_id,v_target_kuri_id,v_gross_prize_amount,
    v_configured_muppu_amount,v_cycle_status
  FROM public.monthly_winners mw
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(
      k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF mw,k,c;

  IF v_target_kuri_id IS NULL THEN RAISE EXCEPTION 'Monthly winner not found.'; END IF;
  IF v_cycle_status<>'COMPLETED' THEN
    RAISE EXCEPTION 'Cycle must be COMPLETED before preparing a payout.';
  END IF;
  IF v_gross_prize_amount<=0 THEN
    RAISE EXCEPTION 'Gross prize amount must be greater than zero.';
  END IF;

  SELECT coalesce(sum(mr.amount),0)
  INTO v_deducted_muppu_amount
  FROM public.muppu_records mr
  WHERE mr.person_id=v_winner_person_id
    AND mr.cycle_id=v_winner_cycle_id
    AND mr.status='DEDUCTED';

  v_payout_muppu_amount:=greatest(
    coalesce(v_configured_muppu_amount,0),v_deducted_muppu_amount
  );

  SELECT po.id,po.status
  INTO v_payout_id,v_payout_status
  FROM public.payouts po
  WHERE po.monthly_winner_id=target_winner_id
  FOR UPDATE;

  IF v_payout_id IS NULL THEN
    INSERT INTO public.payouts(
      monthly_winner_id,gross_amount,muppu_amount,expense_deductions,
      other_deductions,net_amount,status
    )
    VALUES(
      target_winner_id,v_gross_prize_amount,v_payout_muppu_amount,0,0,
      greatest(v_gross_prize_amount-v_payout_muppu_amount,0),'PENDING'
    )
    RETURNING id INTO v_payout_id;
  ELSIF v_payout_status<>'PENDING' THEN
    RETURN v_payout_id;
  END IF;

  SELECT coalesce(sum(eo.amount),0)
  INTO v_expense_deduction_amount
  FROM public.expense_obligations eo
  WHERE eo.deducted_from_payout_id=v_payout_id
    AND eo.status='DEDUCTED_FROM_PRIZE';

  UPDATE public.payouts po
  SET gross_amount=v_gross_prize_amount,
      muppu_amount=v_payout_muppu_amount,
      expense_deductions=v_expense_deduction_amount,
      net_amount=greatest(
        v_gross_prize_amount-v_payout_muppu_amount
        -v_expense_deduction_amount-po.other_deductions,0
      )
  WHERE po.id=v_payout_id
    AND po.status='PENDING';

  RETURN v_payout_id;
END;
$function$;

COMMIT;
