BEGIN;

DO $patch$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
  INTO v_def;

  v_def := replace(
    v_def,
    '  UPDATE public.payouts
  SET expense_deductions=expense_deduction_amount,
      net_amount=greatest(
        gross_amount-muppu_amount-expense_deduction_amount-other_deductions,
        0
      )
  WHERE id=payout_id
    AND status=''PENDING'';',
    '  UPDATE public.payouts p
  SET expense_deductions=expense_deduction_amount,
      net_amount=greatest(
        p.gross_amount-p.muppu_amount-expense_deduction_amount-p.other_deductions,
        0
      )
  WHERE p.id=payout_id
    AND p.status=''PENDING'';'
  );

  EXECUTE v_def;
END
$patch$;

COMMIT;
