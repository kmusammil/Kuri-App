create type public.expense_recurrence_pattern as enum (
  'PER_CYCLE',
  'WEEKLY',
  'MONTHLY',
  'YEARLY',
  'CUSTOM'
);

alter table public.expense_rules
  add column if not exists recurrence_pattern public.expense_recurrence_pattern,
  add column if not exists recurrence_interval integer,
  add column if not exists recurrence_start_date date,
  add column if not exists recurrence_end_date date;

alter table public.expense_obligations
  add column if not exists occurrence_date date;

create table if not exists public.expense_rule_schedule_dates (
  id uuid primary key default gen_random_uuid(),
  expense_rule_id uuid not null references public.expense_rules(id) on delete cascade,
  occurrence_date date not null,
  created_at timestamptz not null default now(),
  constraint expense_rule_schedule_dates_date_check check (occurrence_date is not null),
  constraint expense_rule_schedule_dates_unique_key unique (expense_rule_id, occurrence_date)
);

create index if not exists expense_rule_schedule_dates_rule_date_idx
  on public.expense_rule_schedule_dates (expense_rule_id, occurrence_date);

alter table public.expense_rule_schedule_dates enable row level security;

alter table public.expense_rules
  add constraint expense_rules_recurrence_shape
  check (
    (frequency = 'ONE_TIME'
      and recurrence_pattern is null
      and recurrence_interval is null
      and recurrence_start_date is null
      and recurrence_end_date is null)
    or
    (frequency = 'PER_CYCLE'
      and recurrence_pattern = 'PER_CYCLE'
      and recurrence_interval is null
      and recurrence_start_date is null
      and recurrence_end_date is null)
    or
    (frequency <> 'ONE_TIME'
      and recurrence_pattern is not null)
  );

alter table public.expense_rules
  add constraint expense_rules_recurrence_interval_check
  check (
    recurrence_interval is null
    or recurrence_interval > 0
  );

alter table public.expense_rules
  add constraint expense_rules_recurrence_date_range_check
  check (
    recurrence_end_date is null
    or recurrence_start_date is null
    or recurrence_end_date >= recurrence_start_date
  );

alter table public.expense_obligations
  add constraint expense_obligations_occurrence_date_check
  check (
    occurrence_date is not null
    or cycle_id is not null
  );

create index if not exists expense_obligations_rule_occurrence_idx
  on public.expense_obligations (expense_rule_id, occurrence_date);

create unique index if not exists expense_obligations_recurring_occurrence_key
  on public.expense_obligations (expense_rule_id, membership_id, occurrence_date)
  where occurrence_date is not null;
