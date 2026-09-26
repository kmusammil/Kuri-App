-- EXPENSE/MUPPU reconciliation contract coverage
begin;

select plan(10);

select ok(
  exists (
    select 1
    from pg_enum e
    join pg_type t on t.oid=e.enumtypid
    join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public'
      and t.typname='expense_frequency'
      and e.enumlabel='RECURRING'
  ),
  'canonical recurring Expense frequency exists'
);

select ok(
  not exists (
    select 1
    from public.expense_rules
    where frequency='PER_CYCLE'::public.expense_frequency
  ),
  'no Expense rule is stored with the legacy PER_CYCLE frequency'
);

select ok(
  not exists (
    select 1
    from public.expense_rules
    where frequency='RECURRING'::public.expense_frequency
      and recurrence_pattern is null
  ),
  'recurring Expense rules always have a recurrence pattern'
);

select ok(
  (
    select count(*)
    from public.muppu_records mr
    where exists (
      select 1
      from public.expense_obligations eo
      where eo.settlement_reference like 'LEGACY_MUPPU:'||mr.id::text||'%'
    )
  ) =
  (select count(*) from public.muppu_records),
  'every legacy Muppu record has a canonical Expense obligation'
);

select ok(
  not exists (
    select 1
    from public.muppu_records mr
    where mr.status='DEDUCTED'
      and exists (
        select 1
        from public.expense_obligations eo
        where eo.settlement_reference like 'LEGACY_MUPPU:'||mr.id::text||'%'
          and eo.status<>'DEDUCTED_FROM_PRIZE'
      )
  ),
  'legacy deducted records remain deducted as Expense obligations'
);

select ok(
  not exists (
    select 1
    from public.expense_obligations eo
    join public.payouts po on po.id=eo.deducted_from_payout_id
    where eo.status='DEDUCTED_FROM_PRIZE'
      and (
        po.net_amount <>
          greatest(
            po.gross_amount
            -po.muppu_amount
            -coalesce(po.expense_deductions,0)
            -coalesce(po.other_deductions,0),
            0
          )
      )
  ),
  'linked historical Expense deductions preserve the payout net invariant'
);

select ok(
  exists (
    select 1
    from public.expense_obligations
    where status='DEDUCTED_FROM_PRIZE'
      and settlement_reference like '%HISTORICAL_PAYOUT_UNCHANGED'
  )
  or not exists (
    select 1 from public.muppu_records where status='DEDUCTED'
  ),
  'unreflected historical deductions are explicitly marked without rewriting payout history'
);

select ok(
  pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
    not ilike '%muppu_records%'
    and pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
      ilike '%v_payout_muppu_amount bigint := 0%',
  'new payout preparation no longer reads legacy Muppu records'
);

select ok(
  pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
    not ilike '%muppu_records%'
    and pg_get_functiondef('public.calculate_membership_exit_financials(uuid)'::regprocedure)
      ilike '%expense_obligations%',
  'exit settlement no longer subtracts legacy Muppu records'
);

select ok(
  has_function_privilege(
    'anon',
    'public.create_expense_rule_for_admin(uuid,text,text,public.expense_frequency,bigint,public.expense_recurrence_pattern,integer,date,date,date[],boolean)',
    'EXECUTE'
  ) = false
  and has_function_privilege(
    'anon',
    'public.create_muppu_record_for_admin(uuid,uuid,uuid,bigint)',
    'EXECUTE'
  ) = false,
  'anon cannot execute canonical Expense creation or legacy Muppu creation'
);

select * from finish();
rollback;
