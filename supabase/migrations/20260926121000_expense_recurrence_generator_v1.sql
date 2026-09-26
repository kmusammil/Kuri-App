create or replace function public.generate_expense_obligations_for_rule(
  target_rule_id uuid,
  through_date date
)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  rule_row record;
  occurrence_row record;
  occurrence_count integer := 0;
  inserted_count integer := 0;
  start_date date;
  end_date date;
  cursor_date date;
  interval_value integer;
begin
  if target_rule_id is null or through_date is null then
    raise exception 'Expense rule and generation date are required.';
  end if;

  select
    er.id, er.kuri_id, er.frequency, er.amount, er.active,
    er.recurrence_pattern, er.recurrence_interval,
    er.recurrence_start_date, er.recurrence_end_date
  into rule_row
  from public.expense_rules er
  where er.id = target_rule_id;

  if rule_row.id is null then
    raise exception 'Expense rule not found.';
  end if;

  if not rule_row.active then
    return 0;
  end if;

  if rule_row.frequency = 'ONE_TIME' then
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
    )
    select rule_row.id,rule_row.kuri_id,m.id,null,null,rule_row.amount
    from public.memberships m
    where m.kuri_id=rule_row.kuri_id
      and m.status='ACTIVE'
      and not exists (
        select 1 from public.membership_exits me
        where me.membership_id=m.id
          and me.status in ('PENDING','APPROVED')
      )
    on conflict do nothing;

    get diagnostics inserted_count = row_count;
    return inserted_count;
  end if;

  if rule_row.recurrence_pattern is null then
    raise exception 'Recurring Expense rule is missing recurrence pattern.';
  end if;

  if rule_row.recurrence_pattern = 'PER_CYCLE' then
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
    )
    select rule_row.id,rule_row.kuri_id,m.id,c.id,c.due_date,rule_row.amount
    from public.memberships m
    join public.cycles c on c.kuri_id=m.kuri_id
    where m.kuri_id=rule_row.kuri_id
      and m.status='ACTIVE'
      and c.status not in ('COMPLETED','CANCELLED')
      and c.due_date <= through_date
      and (rule_row.recurrence_start_date is null or c.due_date >= rule_row.recurrence_start_date)
      and (rule_row.recurrence_end_date is null or c.due_date <= rule_row.recurrence_end_date)
      and not exists (
        select 1 from public.membership_exits me
        where me.membership_id=m.id
          and me.status in ('PENDING','APPROVED')
      )
    on conflict do nothing;

    get diagnostics inserted_count = row_count;
    return inserted_count;
  end if;

  start_date := coalesce(rule_row.recurrence_start_date, current_date);

  if start_date > through_date then
    return 0;
  end if;

  end_date := least(through_date,coalesce(rule_row.recurrence_end_date,through_date));
  interval_value := coalesce(rule_row.recurrence_interval,1);

  if interval_value <= 0 then
    raise exception 'Recurrence interval must be greater than zero.';
  end if;

  if rule_row.recurrence_pattern = 'CUSTOM' then
    for occurrence_row in
      select ersd.occurrence_date
      from public.expense_rule_schedule_dates ersd
      where ersd.expense_rule_id=rule_row.id
        and ersd.occurrence_date between start_date and end_date
      order by ersd.occurrence_date
    loop
      insert into public.expense_obligations(
        expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
      )
      select rule_row.id,rule_row.kuri_id,m.id,null,
        occurrence_row.occurrence_date,rule_row.amount
      from public.memberships m
      where m.kuri_id=rule_row.kuri_id
        and m.status='ACTIVE'
        and not exists (
          select 1 from public.membership_exits me
          where me.membership_id=m.id
            and me.status in ('PENDING','APPROVED')
        )
      on conflict do nothing;

      get diagnostics inserted_count = row_count;
      occurrence_count := occurrence_count + inserted_count;
    end loop;

    return occurrence_count;
  end if;

  if rule_row.recurrence_pattern not in ('WEEKLY','MONTHLY','YEARLY') then
    raise exception 'Unsupported recurrence pattern.';
  end if;

  cursor_date := start_date;

  while cursor_date <= end_date loop
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
    )
    select rule_row.id,rule_row.kuri_id,m.id,null,cursor_date,rule_row.amount
    from public.memberships m
    where m.kuri_id=rule_row.kuri_id
      and m.status='ACTIVE'
      and not exists (
        select 1 from public.membership_exits me
        where me.membership_id=me.membership_id
          and me.status in ('PENDING','APPROVED')
      )
    on conflict do nothing;

    get diagnostics inserted_count = row_count;
    occurrence_count := occurrence_count + inserted_count;

    cursor_date :=
      case rule_row.recurrence_pattern
        when 'WEEKLY' then cursor_date + make_interval(weeks => interval_value)
        when 'MONTHLY' then (cursor_date + make_interval(months => interval_value))::date
        when 'YEARLY' then (cursor_date + make_interval(years => interval_value))::date
      end;
  end loop;

  return occurrence_count;
end;
$function$;
