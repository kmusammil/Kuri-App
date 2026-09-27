-- PAYOUT-004: death-before-payout settlement contract

begin;

select plan(6);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%po.id IS NULL OR po.status IN (''PENDING'',''PROCESSING'')%',
  'finalized wins remain payable in death settlement even when payout has not yet been created'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%k.gross_prize_amount%',
  'death settlement derives the unpaid prize from the finalized winner and Kuri gross prize'
);

select ok(
  not (
    pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
      ilike '%po.status IN (''PENDING'',''PROCESSING'') THEN po.net_amount%'
  ),
  'death settlement does not use an already-deducted payout net amount as the gross prize entitlement'
);

select ok(
  pg_get_functiondef('public.record_death_settlement_for_admin(uuid,uuid,text,text)'::regprocedure)
    ilike '%calculate_membership_exit_financials(target_exit_id)%',
  'death settlement action consumes the unified exit financial calculation'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%mw.finalized_at::date<=b.exit_date%',
  'death settlement excludes wins finalized after the verified death date'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%greatest(%'
    and pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
      ilike '%-coalesce(ins.outstanding_amount,0)-coalesce(e.amount,0)-coalesce(mu.amount,0)%',
  'post-win death settlement subtracts remaining installments, expenses, and Muppu'
);

select * from finish();

rollback;
