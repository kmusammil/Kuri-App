set local lock_timeout = '5s';

-- Migrate any legacy Kuri-level amount into the canonical Expense rule model.
insert into public.expense_rules(
  kuri_id,name,description,frequency,amount,active,created_by,recurrence_pattern
)
select
  k.id,
  'Prize Expense',
  'Migrated from the legacy Kuri expense configuration.',
  'ONE_TIME'::public.expense_frequency,
  k.muppu_amount,
  true,
  k.created_by,
  null
from public.kuris k
where k.muppu_amount > 0
  and not exists (
    select 1
    from public.expense_rules er
    where er.kuri_id = k.id
      and er.frequency = 'ONE_TIME'::public.expense_frequency
      and er.amount = k.muppu_amount
  );

drop function if exists public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy
);
drop function if exists public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency
);
drop function if exists public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode
);

create function public.create_kuri_for_admin(
  name text,
  description text,
  start_date date,
  number_of_cycles integer,
  membership_limit integer,
  installment_amount bigint,
  due_day integer,
  draw_day integer,
  gross_prize_amount bigint,
  expense_amount bigint,
  winner_rule text,
  exit_refund_rule public.refund_policy,
  frequency_value public.kuri_frequency,
  schedule_mode_value public.kuri_schedule_mode
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  organization_id uuid;
  kuri_id uuid;
  actor_user_id uuid := auth.uid();
  admin_org_count integer;
  max_day integer;
  expense_rule_id uuid;
begin
  if actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if frequency_value is null or schedule_mode_value is null then
    raise exception 'Frequency and schedule mode are required.';
  end if;

  max_day := case
    when schedule_mode_value='CUSTOM'::public.kuri_schedule_mode then 31
    when frequency_value='WEEKLY'::public.kuri_frequency then 7
    else 31
  end;

  if nullif(btrim(name), '') is null
     or start_date is null
     or number_of_cycles is null or number_of_cycles <= 0
     or membership_limit is null or membership_limit < 1 or membership_limit > 1000
     or installment_amount is null or installment_amount < 0
     or due_day is null or due_day < 1 or due_day > max_day
     or draw_day is null or draw_day < 1 or draw_day > max_day
     or gross_prize_amount is null or gross_prize_amount < 0
     or expense_amount is null or expense_amount < 0
  then
    raise exception 'Please enter valid Kuri details.';
  end if;

  select count(distinct ou.organization_id)
    into admin_org_count
  from public.organization_users ou
  where ou.user_id=actor_user_id
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]);

  if admin_org_count=0 then
    raise exception 'You do not have permission to create a Kuri.';
  elsif admin_org_count>1 then
    raise exception 'Organization context is required to create a Kuri.';
  end if;

  select ou.organization_id
    into organization_id
  from public.organization_users ou
  where ou.user_id=actor_user_id
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by ou.organization_id::text
  limit 1;

  insert into public.kuris(
    organization_id,name,description,start_date,number_of_cycles,
    membership_limit,installment_amount,frequency,schedule_mode,
    due_day,draw_day,gross_prize_amount,muppu_amount,winner_rule,
    exit_refund_rule,created_by
  )
  values(
    organization_id,
    btrim(name),
    nullif(btrim(description),''),
    start_date,
    number_of_cycles,
    membership_limit,
    installment_amount,
    frequency_value,
    schedule_mode_value,
    due_day,
    draw_day,
    gross_prize_amount,
    0,
    coalesce(nullif(btrim(winner_rule),''),'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_rule,'AT_MATURITY'::public.refund_policy),
    actor_user_id
  )
  returning id into kuri_id;

  insert into public.kuri_admins(kuri_id,user_id,role)
  values(kuri_id,actor_user_id,'MAIN_ADMIN');

  if expense_amount > 0 then
    insert into public.expense_rules(
      kuri_id,name,description,frequency,amount,active,created_by,recurrence_pattern
    )
    values(
      kuri_id,
      'Prize Expense',
      'Default one-time Expense applied to a membership when applicable to settlement or prize deduction.',
      'ONE_TIME'::public.expense_frequency,
      expense_amount,
      true,
      (select u.id from public.users u where u.id=actor_user_id),
      null
    )
    returning id into expense_rule_id;

    perform public.sync_expense_obligations_for_rule(expense_rule_id);
  end if;

  return kuri_id;
end
$function$;

revoke all on function public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode
) from public, anon;

grant execute on function public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode
) to authenticated;
