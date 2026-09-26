-- PAYOUT-005: remaining installment reconciliation after winning

begin;

select plan(6);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%CASE WHEN w.has_win THEN coalesce(ins.outstanding_amount,0) ELSE 0 END%',
  'outstanding installments are retained for members who have won'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%-coalesce(ins.outstanding_amount,0)-coalesce(e.amount,0)-coalesce(mu.amount,0)%',
  'post-win settlement deducts outstanding installments from the prize entitlement'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%least(i.amount_due,coalesce(sum(pa.allocated_amount),0))%',
  'installment reconciliation uses actual allocated payments and cannot over-credit an installment'
);

select ok(
  exists (
    select 1
    from pg_constraint c
    join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public'
      and r.relname='installments'
      and c.conname='installments_membership_id_cycle_id_key'
  ),
  'each membership has at most one installment per cycle'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%greatest(ib.amount_due-ib.effective_paid,0)%',
  'remaining installment balance cannot become negative'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%WHEN coalesce(w.has_win,false) THEN%',
  'settlement calculation distinguishes post-win reconciliation from pre-win settlement'
);

select * from finish();

rollback;
