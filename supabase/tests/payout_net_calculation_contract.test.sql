-- PAYOUT-002: gross -> deductions -> net calculation contract

begin;

select plan(6);

select ok(
  exists (
    select 1 from pg_constraint c
    join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='payouts'
      and c.conname='payouts_net_amount_invariant'
      and pg_get_constraintdef(c.oid) ilike '%gross_amount - muppu_amount%expense_deductions%other_deductions%'
  ),
  'payout table enforces the gross-minus-deductions net invariant'
);

select ok(
  pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
    ilike '%greatest(%gross_prize_amount-v_payout_muppu_amount-v_expense_deduction_amount-po.other_deductions,0)%',
  'payout preparation calculates net from gross minus all deductions'
);

select ok(
  pg_get_functiondef('public.mark_payout_paid_for_admin(uuid,timestamp with time zone,payment_method,text,text,text,bigint)'::regprocedure)
    ilike '%po.gross_amount-po.muppu_amount-expense_deduction_amount-po.other_deductions%',
  'payout payment recalculates net from persisted deductions'
);

select ok(
  pg_get_functiondef('public.mark_payout_paid_for_admin(uuid,timestamp with time zone,payment_method,text,text,text,bigint)'::regprocedure)
    ilike '%payout_other_deductions<0%',
  'negative other deductions are rejected'
);

select ok(
  exists (
    select 1 from pg_constraint c
    join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='payouts'
      and c.conname='payouts_net_amount_check'
  ),
  'negative net payouts are rejected'
);

select ok(
  exists (
    select 1 from pg_constraint c
    join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='payouts'
      and c.conname='payouts_other_deductions_check'
  ),
  'negative other deductions are rejected at database level'
);

select * from finish();

rollback;
