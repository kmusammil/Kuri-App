-- PAYOUT-001: generalized Expense integration contract

begin;

select plan(6);

select ok(
  to_regprocedure('public.prepare_payout_for_admin(uuid)') is not null,
  'payout preparation API exists'
);

select ok(
  pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
    ilike '%expense_obligations%',
  'payout preparation reads generalized expense obligations'
);

select ok(
  pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
    ilike '%DEDUCTED_FROM_PRIZE%',
  'only prize-deducted expense obligations are included'
);

select ok(
  pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
    ilike '%expense_deductions%',
  'payout stores the generalized expense deduction amount'
);

select ok(
  pg_get_functiondef('public.mark_payout_paid_for_admin(uuid,timestamp with time zone,payment_method,text,text,text,bigint)'::regprocedure)
    ilike '%expense_obligations%',
  'payout payment processing re-reads generalized expense deductions'
);

select ok(
  pg_get_functiondef('public.mark_payout_paid_for_admin(uuid,timestamp with time zone,payment_method,text,text,text,bigint)'::regprocedure)
    ilike '%po.gross_amount-po.muppu_amount-expense_deduction_amount-po.other_deductions%',
  'net payout calculation subtracts generalized expense deductions'
);

select * from finish();

rollback;
