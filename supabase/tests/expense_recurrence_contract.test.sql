-- Expense recurrence contract coverage (pgTAP)
begin;

select plan(21);

select ok(
  exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public'
      and t.typname='expense_recurrence_pattern'
      and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='PER_CYCLE')
      and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='WEEKLY')
      and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='MONTHLY')
      and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='YEARLY')
      and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='CUSTOM')
  ),
  'expense recurrence pattern vocabulary exists'
);

select is(
  (select data_type from information_schema.columns where table_schema='public' and table_name='expense_rules' and column_name='recurrence_interval'),
  'integer',
  'expense rule recurrence interval exists'
);

select ok(
  exists (select 1 from information_schema.columns where table_schema='public' and table_name='expense_rules' and column_name='recurrence_start_date')
  and exists (select 1 from information_schema.columns where table_schema='public' and table_name='expense_rules' and column_name='recurrence_end_date'),
  'expense rule recurrence date bounds exist'
);

select ok(
  exists (select 1 from information_schema.columns where table_schema='public' and table_name='expense_obligations' and column_name='occurrence_date'),
  'expense obligation occurrence date exists'
);

select ok(
  exists (select 1 from pg_class where oid='public.expense_rule_schedule_dates'::regclass)
  and exists (select 1 from pg_class where oid='public.expense_rule_schedule_dates'::regclass and relrowsecurity),
  'custom expense schedule table exists with RLS'
);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.expense_rule_schedule_dates_rule_date_key'::regclass
      and indisunique
  ),
  'custom schedule dates are unique per rule'
);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.expense_obligations_recurring_occurrence_key'::regclass
      and indisunique
  ),
  'recurring expense occurrences are idempotently unique'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='generate_expense_obligations_for_rule'
      and pg_get_function_identity_arguments(p.oid)='target_rule_id uuid, through_date date'
  ),
  'general recurrence generator exists'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='generate_expense_obligations_for_membership_rule'
  ),
  'membership-scoped recurrence generator exists'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='sync_expense_obligations_for_rule'
      and pg_get_functiondef(p.oid) ilike '%generate_expense_obligations_for_rule%'
  ),
  'rule sync delegates to recurrence generator'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='sync_expense_obligations_for_membership'
      and pg_get_functiondef(p.oid) ilike '%generate_expense_obligations_for_membership_rule%'
  ),
  'membership sync delegates to membership-scoped generator'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='sync_expense_obligations_for_kuri'
      and pg_get_functiondef(p.oid) ilike '%sync_expense_obligations_for_rule%'
  ),
  'Kuri sync delegates to rule sync'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='create_expense_rule_for_admin'
      and pg_get_functiondef(p.oid) ilike '%recurrence_pattern_value%'
      and pg_get_functiondef(p.oid) ilike '%custom_schedule_dates%'
  ),
  'Expense rule creation API accepts recurrence configuration'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.expense_rules'::regclass
      and conname='expense_rules_recurrence_shape'
  ),
  'expense recurrence shape constraint exists'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.expense_rules'::regclass
      and conname='expense_rules_recurrence_interval_check'
  ),
  'expense recurrence interval constraint exists'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.expense_rules'::regclass
      and conname='expense_rules_recurrence_date_range_check'
  ),
  'expense recurrence date range constraint exists'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.expense_obligations'::regclass
      and conname='expense_obligations_occurrence_date_check'
  ),
  'expense obligation occurrence date constraint exists'
);

select ok(
  (select count(*) from public.expense_obligations where occurrence_date is not null)
  =
  (select count(*) from public.expense_obligations where occurrence_date is not null),
  'existing recurring obligation rows are internally queryable'
);

select ok(
  has_function_privilege(
    'anon',
    'public.create_expense_rule_for_admin(uuid,text,text,public.expense_frequency,bigint,public.expense_recurrence_pattern,integer,date,date,date[],boolean)',
    'EXECUTE'
  ) = false,
  'recurrence-aware Expense creation is not executable by anon'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.create_expense_rule_for_admin(uuid,text,text,public.expense_frequency,bigint,public.expense_recurrence_pattern,integer,date,date,date[],boolean)',
    'EXECUTE'
  ) = true,
  'recurrence-aware Expense creation is executable by authenticated users'
);

select ok(
  has_function_privilege(
    'anon',
    'public.generate_expense_obligations_for_rule(uuid,date)',
    'EXECUTE'
  ) = false
  and has_function_privilege(
    'anon',
    'public.generate_expense_obligations_for_membership_rule(uuid,uuid,date)',
    'EXECUTE'
  ) = false,
  'internal Expense generators are not executable by anon'
);

select * from finish();
rollback;
