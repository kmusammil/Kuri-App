BEGIN;

ALTER TABLE public.payouts
  ADD COLUMN IF NOT EXISTS expense_deductions bigint NOT NULL DEFAULT 0;

ALTER TABLE public.payouts
  DROP CONSTRAINT IF EXISTS payouts_net_amount_invariant;

ALTER TABLE public.payouts
  ADD CONSTRAINT payouts_expense_deductions_check CHECK (expense_deductions >= 0);

ALTER TABLE public.payouts
  ADD CONSTRAINT payouts_net_amount_invariant
  CHECK (
    net_amount = greatest(
      gross_amount - muppu_amount - expense_deductions - other_deductions,
      0
    )
  );

DO $patch$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
  INTO v_def;

  v_def := replace(
    v_def,
    '  cycle_status_value public.cycle_status;',
    E'  cycle_status_value public.cycle_status;\n  expense_deduction_amount bigint;'
  );
  v_def := replace(
    v_def,
    '    monthly_winner_id,gross_amount,muppu_amount,other_deductions,net_amount,status',
    '    monthly_winner_id,gross_amount,muppu_amount,expense_deductions,other_deductions,net_amount,status'
  );
  v_def := replace(
    v_def,
    '    target_winner_id,gross_amount,payout_muppu_amount,0,',
    '    target_winner_id,gross_amount,payout_muppu_amount,0,0,'
  );
  v_def := replace(
    v_def,
    '      excluded.gross_amount-excluded.muppu_amount-public.payouts.other_deductions,',
    '      excluded.gross_amount-excluded.muppu_amount-excluded.expense_deductions-public.payouts.other_deductions,'
  );
  v_def := replace(
    v_def,
    '  RETURN payout_id;',
    E'  SELECT coalesce(sum(eo.amount),0)\n    INTO expense_deduction_amount\n  FROM public.expense_obligations eo\n  WHERE eo.deducted_from_payout_id=payout_id\n    AND eo.status=''DEDUCTED_FROM_PRIZE'';\n\n  UPDATE public.payouts\n  SET expense_deductions=expense_deduction_amount,\n      net_amount=greatest(\n        gross_amount-muppu_amount-expense_deduction_amount-other_deductions,\n        0\n      )\n  WHERE id=payout_id\n    AND status=''PENDING'';\n\n  RETURN payout_id;'
  );
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.mark_payout_paid_for_admin(uuid,timestamp with time zone,payment_method,text,text,text,bigint)'::regprocedure
  )
  INTO v_def;

  v_def := replace(
    v_def,
    '  computed_net_amount bigint;',
    E'  computed_net_amount bigint;\n  expense_deduction_amount bigint;'
  );
  v_def := replace(
    v_def,
    '  PERFORM public.transition_payout_status_for_admin(payout_row.id,''PROCESSING'');',
    E'  SELECT coalesce(sum(eo.amount),0)\n    INTO expense_deduction_amount\n  FROM public.expense_obligations eo\n  WHERE eo.deducted_from_payout_id=payout_row.id\n    AND eo.status=''DEDUCTED_FROM_PRIZE'';\n\n  UPDATE public.payouts\n  SET expense_deductions=expense_deduction_amount,\n      net_amount=greatest(\n        gross_amount-muppu_amount-expense_deduction_amount-other_deductions,\n        0\n      )\n  WHERE id=payout_row.id;\n\n  payout_row.expense_deductions:=expense_deduction_amount;\n\n  PERFORM public.transition_payout_status_for_admin(payout_row.id,''PROCESSING'');'
  );
  v_def := replace(
    v_def,
    '    payout_row.gross_amount-payout_row.muppu_amount-payout_other_deductions,',
    '    payout_row.gross_amount-payout_row.muppu_amount-payout_row.expense_deductions-payout_other_deductions,'
  );
  v_def := replace(
    v_def,
    '  SET other_deductions=payout_other_deductions,',
    '  SET other_deductions=payout_other_deductions,\n      expense_deductions=expense_deduction_amount,'
  );
  EXECUTE v_def;
END
$patch$;

DO $patch$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.deduct_expense_from_prize_for_admin(uuid,uuid,text)'::regprocedure
  )
  INTO v_def;

  v_def := replace(
    v_def,
    '  payout_status public.payout_status;',
    E'  payout_status public.payout_status;\n  obligation_amount bigint;'
  );
  v_def := replace(
    v_def,
    E'  UPDATE public.expense_obligations\n  SET status=''DEDUCTED_FROM_PRIZE'',',
    E'  SELECT eo.amount\n    INTO obligation_amount\n  FROM public.expense_obligations eo\n  WHERE eo.id=target_obligation_id;\n\n  UPDATE public.expense_obligations\n  SET status=''DEDUCTED_FROM_PRIZE'','
  );
  v_def := replace(
    v_def,
    E'  IF NOT FOUND THEN\n    RAISE EXCEPTION ''Only unpaid Expense obligations can be deducted from a prize.'';\n  END IF;',
    E'  IF NOT FOUND THEN\n    RAISE EXCEPTION ''Only unpaid Expense obligations can be deducted from a prize.'';\n  END IF;\n\n  UPDATE public.payouts\n  SET expense_deductions=expense_deductions+obligation_amount,\n      net_amount=greatest(\n        gross_amount-muppu_amount-(expense_deductions+obligation_amount)-other_deductions,\n        0\n      )\n  WHERE id=target_payout_id\n    AND status=''PENDING'';'
  );
  EXECUTE v_def;
END
$patch$;

DROP FUNCTION public.get_payout_for_admin(uuid);

CREATE FUNCTION public.get_payout_for_admin(target_winner_id uuid)
RETURNS TABLE(
  payout_id uuid,winner_id uuid,person_id uuid,registered_name text,display_name text,
  gross_amount bigint,muppu_amount bigint,expense_deductions bigint,other_deductions bigint,
  net_amount bigint,payment_date timestamptz,method public.payment_method,
  reference_number text,status public.payout_status,processed_by uuid,notes text,created_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='public'
AS $function$
  SELECT po.id,mw.id,mw.person_id,p.registered_name,p.display_name,
         po.gross_amount,po.muppu_amount,po.expense_deductions,po.other_deductions,po.net_amount,
         po.payment_date,po.method,po.reference_number,po.status,po.processed_by,po.notes,po.created_at
  FROM public.payouts po
  JOIN public.monthly_winners mw ON mw.id=po.monthly_winner_id
  JOIN public.people p ON p.id=mw.person_id
  JOIN public.cycles c ON c.id=mw.cycle_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

DROP FUNCTION public.list_payouts_for_admin(uuid);

CREATE FUNCTION public.list_payouts_for_admin(target_kuri_id uuid DEFAULT NULL)
RETURNS TABLE(
  payout_id uuid,winner_id uuid,cycle_number integer,person_id uuid,registered_name text,display_name text,
  gross_amount bigint,muppu_amount bigint,expense_deductions bigint,other_deductions bigint,
  net_amount bigint,payment_date timestamptz,method public.payment_method,
  reference_number text,status public.payout_status
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='public'
AS $function$
  SELECT po.id,mw.id,c.cycle_number,mw.person_id,p.registered_name,p.display_name,
         po.gross_amount,po.muppu_amount,po.expense_deductions,po.other_deductions,po.net_amount,
         po.payment_date,po.method,po.reference_number,po.status
  FROM public.payouts po
  JOIN public.monthly_winners mw ON mw.id=po.monthly_winner_id
  JOIN public.people p ON p.id=mw.person_id
  JOIN public.cycles c ON c.id=mw.cycle_id
  WHERE (target_kuri_id IS NULL OR c.kuri_id=target_kuri_id)
    AND public.has_kuri_admin_role(c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY c.cycle_number DESC,po.created_at DESC;
$function$;

GRANT EXECUTE ON FUNCTION public.get_payout_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_payouts_for_admin(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.get_payout_for_admin(uuid) FROM anon,public;
REVOKE ALL ON FUNCTION public.list_payouts_for_admin(uuid) FROM anon,public;

COMMIT;
