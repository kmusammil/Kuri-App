-- WINNER-008: winner obligations integrated into exit/death settlement

begin;

select plan(5);

select ok(
  to_regprocedure('public.calculate_membership_exit_financials(uuid)') is not null,
  'membership exit financial calculation API exists'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%case when w.has_win then coalesce(ins.outstanding_amount,0) else 0 end%',
  'outstanding installments are included after a win'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%coalesce(w.pending_prize,0)+coalesce(au.unallocated_amount,0)%'
    and pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
      ilike '%-coalesce(ins.outstanding_amount,0)-coalesce(e.amount,0)-coalesce(mu.amount,0)%',
  'post-win settlement subtracts remaining installment obligations and applicable deductions'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    ilike '%monthly_winner_memberships%'
    and pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
      ilike '%monthly_winners%',
  'settlement detects finalized wins through winner records'
);

select ok(
  pg_get_functiondef('public.settle_membership_exit_for_admin(uuid,muppu_settlement_method,text,timestamp with time zone,text)'::regprocedure)
    ilike '%calculate_membership_exit_financials%'
    and pg_get_functiondef('public.approve_membership_exit_for_admin(uuid)'::regprocedure)
      ilike '%calculate_membership_exit_financials%',
  'exit settlement and approval consume the integrated financial calculation'
);

select * from finish();

rollback;
