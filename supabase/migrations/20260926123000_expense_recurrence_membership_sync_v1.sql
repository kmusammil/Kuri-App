create or replace function public.generate_expense_obligations_for_membership_rule(
  target_rule_id uuid,
  target_membership_id uuid,
  through_date date
)
returns integer
language plpgsql
security definer
set search_path to ''
as $function$
declare
  rule_row public.expense_rules%rowtype;
  schedule_row record;
  occurrence date;
  start_date date;
  end_date date;
  interval_value integer;
  occurrence_count integer := 0;
  inserted_count integer := 0;
begin
  select * into rule_row from public.expense_rules where id=target_rule_id and active;
  if not found or target_membership_id is null or through_date is null then return 0; end if;

  if not exists (
    select 1 from public.memberships m
    where m.id=target_membership_id and m.kuri_id=rule_row.kuri_id and m.status='ACTIVE'
      and not exists (
        select 1 from public.membership_exits me
        where me.membership_id=m.id and me.status in ('PENDING','APPROVED')
      )
  ) then return 0; end if;

  if rule_row.frequency='ONE_TIME' then
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
    ) values (rule_row.id,rule_row.kuri_id,target_membership_id,null,rule_row.amount,null)
    on conflict do nothing;
    get diagnostics inserted_count = row_count;
    return inserted_count;
  end if;

  if coalesce(rule_row.recurrence_pattern,'PER_CYCLE')='PER_CYCLE' then
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
    )
    select rule_row.id,rule_row.kuri_id,target_membership_id,c.id,rule_row.amount,c.due_date
    from public.cycles c
    where c.kuri_id=rule_row.kuri_id
      and c.status not in ('COMPLETED','CANCELLED')
      and c.due_date <= through_date
    on conflict do nothing;
    get diagnostics inserted_count = row_count;
    return inserted_count;
  end if;

  start_date := coalesce(rule_row.recurrence_start_date,current_date);
  end_date := least(through_date,coalesce(rule_row.recurrence_end_date,through_date));
  interval_value := greatest(coalesce(rule_row.recurrence_interval,1),1);
  if start_date > end_date then return 0; end if;

  if coalesce(rule_row.recurrence_pattern,'PER_CYCLE')='CUSTOM' then
    for schedule_row in
      select occurrence_date from public.expense_rule_schedule_dates
      where expense_rule_id=rule_row.id and occurrence_date between start_date and end_date
      order by occurrence_date
    loop
      insert into public.expense_obligations(
        expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
      ) values (
        rule_row.id,rule_row.kuri_id,target_membership_id,null,
        rule_row.amount,schedule_row.occurrence_date
      ) on conflict do nothing;
      get diagnostics inserted_count = row_count;
      occurrence_count := occurrence_count + inserted_count;
    end loop;
    return occurrence_count;
  end if;

  occurrence := start_date;
  while occurrence <= end_date loop
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
    ) values (rule_row.id,rule_row.kuri_id,target_membership_id,null,rule_row.amount,occurrence)
    on conflict do nothing;
    get diagnostics inserted_count = row_count;
    occurrence_count := occurrence_count + inserted_count;

    case coalesce(rule_row.recurrence_pattern,'PER_CYCLE')
      when 'WEEKLY' then occurrence := (occurrence + make_interval(days => 7 * interval_value))::date;
      when 'MONTHLY' then occurrence := (occurrence + make_interval(months => interval_value))::date;
      when 'YEARLY' then occurrence := (occurrence + make_interval(years => interval_value))::date;
      else raise exception 'Unsupported expense recurrence pattern: %',rule_row.recurrence_pattern;
    end case;
  end loop;
  return occurrence_count;
end;
$function$;

create or replace function public.sync_expense_obligations_for_membership(target_membership_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  target_kuri_id uuid;
  through_date date;
  rule_row record;
begin
  select m.kuri_id into target_kuri_id
  from public.memberships m
  where m.id=target_membership_id and m.status='ACTIVE'
    and not exists (
      select 1 from public.membership_exits me
      where me.membership_id=m.id and me.status in ('PENDING','APPROVED')
    );

  if target_kuri_id is null then return; end if;

  select coalesce(max(c.due_date),current_date) into through_date
  from public.cycles c where c.kuri_id=target_kuri_id;

  for rule_row in
    select er.id from public.expense_rules er
    where er.kuri_id=target_kuri_id and er.active
    order by er.id
  loop
    perform public.generate_expense_obligations_for_membership_rule(
      rule_row.id,target_membership_id,through_date
    );
  end loop;
end;
$function$;
