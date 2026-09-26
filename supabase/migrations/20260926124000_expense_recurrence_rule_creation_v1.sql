create or replace function public.create_expense_rule_for_admin(
  target_kuri_id uuid,
  expense_name text,
  expense_description text,
  expense_frequency_value public.expense_frequency,
  expense_amount bigint,
  recurrence_pattern_value public.expense_recurrence_pattern,
  recurrence_interval_value integer default null,
  recurrence_start_date_value date default null,
  recurrence_end_date_value date default null,
  custom_schedule_dates date[] default null,
  activate_rule boolean default true
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  actor_id uuid := auth.uid();
  kuri_status_value public.kuri_status;
  rule_id uuid;
  schedule_date date;
begin
  if actor_id is null then raise exception 'You must be signed in.'; end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to manage Expenses for this Kuri.';
  end if;

  select k.status into kuri_status_value
  from public.kuris k where k.id=target_kuri_id for update;

  if kuri_status_value is null then raise exception 'Kuri not found.'; end if;
  if kuri_status_value in ('COMPLETED','ARCHIVED') then
    raise exception 'Expense rules cannot be added to a completed or archived Kuri.';
  end if;

  if char_length(btrim(coalesce(expense_name,''))) not between 1 and 200 then
    raise exception 'Expense name must be 1-200 characters.';
  end if;
  if expense_amount is null or expense_amount<=0 then
    raise exception 'Expense amount must be greater than zero.';
  end if;
  if expense_frequency_value is null then
    raise exception 'Expense frequency is required.';
  end if;

  if expense_frequency_value='ONE_TIME' then
    if recurrence_pattern_value is not null
       or recurrence_interval_value is not null
       or recurrence_start_date_value is not null
       or recurrence_end_date_value is not null
       or coalesce(cardinality(custom_schedule_dates),0)>0 then
      raise exception 'One-time Expenses cannot have recurrence settings.';
    end if;
  else
    if recurrence_pattern_value is null then
      raise exception 'Recurring Expense requires a recurrence pattern.';
    end if;

    if recurrence_pattern_value='PER_CYCLE' then
      if recurrence_interval_value is not null
         or recurrence_start_date_value is not null
         or recurrence_end_date_value is not null
         or coalesce(cardinality(custom_schedule_dates),0)>0 then
        raise exception 'Per-cycle Expenses cannot have calendar recurrence settings.';
      end if;
    elsif recurrence_pattern_value in ('WEEKLY','MONTHLY','YEARLY') then
      if coalesce(recurrence_interval_value,1)<=0 then
        raise exception 'Recurrence interval must be greater than zero.';
      end if;
      if coalesce(cardinality(custom_schedule_dates),0)>0 then
        raise exception 'Calendar recurrence cannot have custom schedule dates.';
      end if;
      if recurrence_end_date_value is not null
         and recurrence_end_date_value < coalesce(recurrence_start_date_value,current_date) then
        raise exception 'Recurrence end date cannot be before the start date.';
      end if;
    elsif recurrence_pattern_value='CUSTOM' then
      if coalesce(cardinality(custom_schedule_dates),0)=0 then
        raise exception 'Custom recurrence requires at least one schedule date.';
      end if;
      if recurrence_interval_value is not null then
        raise exception 'Custom recurrence cannot have a recurrence interval.';
      end if;
      if recurrence_end_date_value is not null
         and recurrence_end_date_value < coalesce(recurrence_start_date_value,current_date) then
        raise exception 'Recurrence end date cannot be before the start date.';
      end if;
    end if;
  end if;

  insert into public.expense_rules(
    kuri_id,name,description,frequency,amount,active,created_by,
    recurrence_pattern,recurrence_interval,recurrence_start_date,recurrence_end_date
  )
  values(
    target_kuri_id,btrim(expense_name),nullif(btrim(expense_description),''),
    expense_frequency_value,expense_amount,coalesce(activate_rule,true),
    (select id from public.users where id=actor_id),
    case when expense_frequency_value='ONE_TIME' then null else recurrence_pattern_value end,
    case when recurrence_pattern_value in ('WEEKLY','MONTHLY','YEARLY')
         then coalesce(recurrence_interval_value,1) else null end,
    case when recurrence_pattern_value in ('WEEKLY','MONTHLY','YEARLY','CUSTOM')
         then coalesce(recurrence_start_date_value,current_date) else null end,
    case when recurrence_pattern_value in ('WEEKLY','MONTHLY','YEARLY','CUSTOM')
         then recurrence_end_date_value else null end
  )
  returning id into rule_id;

  if recurrence_pattern_value='CUSTOM' then
    foreach schedule_date in array custom_schedule_dates loop
      insert into public.expense_rule_schedule_dates(expense_rule_id,occurrence_date)
      values(rule_id,schedule_date)
      on conflict do nothing;
    end loop;
  end if;

  perform public.sync_expense_obligations_for_rule(rule_id);
  return rule_id;
end
$function$;
