-- EXPENSE-001: generalized Expense architecture contract

begin;

select plan(8);

select ok(
  exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='expense_frequency'
  ),
  'generalized Expense frequency type exists'
);

select ok(
  (select count(*) from pg_enum e join pg_type t on t.oid=e.enumtypid
   join pg_namespace n on n.oid=t.typnamespace
   where n.nspname='public' and t.typname='expense_frequency'
     and e.enumlabel in ('ONE_TIME','PER_CYCLE')) = 2,
  'Expense supports one-time and per-cycle rules'
);

select ok(
  exists (
    select 1 from pg_class r join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='expense_rules' and r.relrowsecurity
  ),
  'Expense rules have RLS enabled'
);

select ok(
  exists (
    select 1 from pg_class r join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='expense_obligations' and r.relrowsecurity
  ),
  'Expense obligations have RLS enabled'
);

select ok(
  (select count(*) from pg_enum e join pg_type t on t.oid=e.enumtypid
   join pg_namespace n on n.oid=t.typnamespace
   where n.nspname='public' and t.typname='expense_obligation_status'
     and e.enumlabel in ('UNPAID','PAID','WAIVED','DEDUCTED_FROM_PRIZE')) = 4,
  'Expense obligations support the required financial states'
);

select ok(
  pg_get_functiondef('public.sync_expense_obligations_for_rule(uuid)'::regprocedure)
    ilike '%frequency=''ONE_TIME''%'
    and pg_get_functiondef('public.sync_expense_obligations_for_rule(uuid)'::regprocedure)
    ilike '%c.status NOT IN (''COMPLETED'',''CANCELLED'')%',
  'one-time and per-cycle obligations are generated with the correct cycle scope'
);

select ok(
  pg_get_functiondef('public.deduct_expense_from_prize_for_admin(uuid,uuid,text)'::regprocedure)
    ilike '%status=''DEDUCTED_FROM_PRIZE''%'
    and pg_get_functiondef('public.deduct_expense_from_prize_for_admin(uuid,uuid,text)'::regprocedure)
    ilike '%deducted_from_payout_id=target_payout_id%',
  'Expense obligations can be settled by deduction from prize'
);

select ok(
  exists (
    select 1 from pg_constraint c
    join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='expense_obligations'
      and c.conname='expense_obligations_settlement_shape'
  ),
  'Expense obligation settlement shape is database-enforced'
);

select * from finish();

rollback;
