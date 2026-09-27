-- CYCLE-005 + CYCLE-006: complete regular/custom scheduling model
create type public.kuri_schedule_mode as enum ('REGULAR','CUSTOM');

alter type public.kuri_frequency add value if not exists 'YEARLY';

alter table public.kuris
  add column if not exists schedule_mode public.kuri_schedule_mode not null default 'REGULAR';

create table if not exists public.kuri_custom_cycle_schedules (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete cascade,
  cycle_number integer not null,
  period_start date not null,
  period_end date not null,
  due_date date not null,
  draw_date date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kuri_custom_cycle_schedules_cycle_number_check check (cycle_number >= 1),
  constraint kuri_custom_cycle_schedules_period_check check (period_start <= period_end),
  constraint kuri_custom_cycle_schedules_due_date_check check (due_date between period_start and period_end),
  constraint kuri_custom_cycle_schedules_draw_date_check check (draw_date between period_start and period_end),
  constraint kuri_custom_cycle_schedules_unique_cycle unique (kuri_id, cycle_number)
);

alter table public.kuri_custom_cycle_schedules enable row level security;

create or replace function public.set_custom_cycle_schedule_for_admin(
  target_kuri_id uuid,
  target_cycle_number integer,
  target_period_start date,
  target_period_end date,
  target_due_date date,
  target_draw_date date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  schedule_id uuid;
  kuri_row public.kuris%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.* into kuri_row
  from public.kuris k
  where k.id = target_kuri_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update;

  if not found then
    raise exception 'You do not have permission to manage this Kuri.';
  end if;

  if kuri_row.schedule_mode <> 'CUSTOM'::public.kuri_schedule_mode then
    raise exception 'Custom cycle dates require CUSTOM scheduling mode.';
  end if;

  if kuri_row.status not in ('DRAFT','OPEN','ACTIVE') then
    raise exception 'Custom schedule cannot be changed after Kuri completion.';
  end if;

  if target_cycle_number is null
     or target_cycle_number < 1
     or target_cycle_number > kuri_row.number_of_cycles then
    raise exception 'Invalid custom cycle number.';
  end if;

  if target_period_start is null
     or target_period_end is null
     or target_period_start > target_period_end then
    raise exception 'Invalid custom cycle period.';
  end if;

  if target_due_date is null
     or target_due_date < target_period_start
     or target_due_date > target_period_end then
    raise exception 'Due date must fall inside the custom cycle period.';
  end if;

  if target_draw_date is null
     or target_draw_date < target_period_start
     or target_draw_date > target_period_end then
    raise exception 'Draw date must fall inside the custom cycle period.';
  end if;

  if target_period_start < current_date then
    raise exception 'Custom cycle period cannot start in the past.';
  end if;

  if exists (
    select 1
    from public.cycles c
    where c.kuri_id = target_kuri_id
      and c.cycle_number = target_cycle_number
  ) then
    raise exception 'This cycle has already been generated and cannot be rescheduled here.';
  end if;

  insert into public.kuri_custom_cycle_schedules(
    kuri_id, cycle_number, period_start, period_end, due_date, draw_date
  )
  values (
    target_kuri_id, target_cycle_number, target_period_start,
    target_period_end, target_due_date, target_draw_date
  )
  on conflict (kuri_id, cycle_number)
  do update set
    period_start = excluded.period_start,
    period_end = excluded.period_end,
    due_date = excluded.due_date,
    draw_date = excluded.draw_date,
    updated_at = now()
  returning id into schedule_id;

  return schedule_id;
end;
$function$;

revoke all on function public.set_custom_cycle_schedule_for_admin(uuid,integer,date,date,date,date) from public, anon;
grant execute on function public.set_custom_cycle_schedule_for_admin(uuid,integer,date,date,date,date) to authenticated;

create or replace function public.create_kuri_for_admin(
  name text,
  description text,
  start_date date,
  number_of_cycles integer,
  membership_limit integer,
  installment_amount bigint,
  due_day integer,
  draw_day integer,
  gross_prize_amount bigint,
  muppu_amount bigint,
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
  admin_org_count integer;
  max_day integer;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if frequency_value is null or schedule_mode_value is null then
    raise exception 'Frequency and schedule mode are required.';
  end if;

  if schedule_mode_value = 'CUSTOM'::public.kuri_schedule_mode then
    max_day := 31;
  elsif frequency_value = 'WEEKLY'::public.kuri_frequency then
    max_day := 7;
  else
    max_day := 31;
  end if;

  if nullif(trim(name),'') is null
     or start_date is null
     or number_of_cycles is null
     or number_of_cycles <= 0
     or membership_limit is null
     or membership_limit < 1
     or membership_limit > 1000
     or installment_amount is null
     or installment_amount < 0
     or due_day is null
     or due_day < 1
     or due_day > max_day
     or draw_day is null
     or draw_day < 1
     or draw_day > max_day
     or gross_prize_amount is null
     or gross_prize_amount < 0
     or muppu_amount is null
     or muppu_amount < 0 then
    raise exception 'Please enter valid Kuri details.';
  end if;

  select count(distinct ou.organization_id)
    into admin_org_count
  from public.organization_users ou
  where ou.user_id = auth.uid()
    and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[]);

  if admin_org_count = 0 then
    raise exception 'You do not have permission to create a Kuri.';
  elsif admin_org_count > 1 then
    raise exception 'Organization context is required to create a Kuri.';
  end if;

  select ou.organization_id into organization_id
  from public.organization_users ou
  where ou.user_id = auth.uid()
    and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by ou.organization_id::text
  limit 1;

  insert into public.kuris(
    organization_id,name,description,start_date,number_of_cycles,
    membership_limit,installment_amount,frequency,schedule_mode,
    due_day,draw_day,gross_prize_amount,muppu_amount,winner_rule,
    exit_refund_rule,created_by
  )
  values(
    organization_id,trim(name),nullif(trim(description),''),
    start_date,number_of_cycles,membership_limit,installment_amount,
    frequency_value,schedule_mode_value,due_day,draw_day,
    gross_prize_amount,muppu_amount,
    coalesce(nullif(trim(winner_rule),''),'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_rule,'AT_MATURITY'),auth.uid()
  )
  returning id into kuri_id;

  insert into public.kuri_admins(kuri_id,user_id,role)
  values(kuri_id,auth.uid(),'MAIN_ADMIN');

  return kuri_id;
end;
$function$;

revoke all on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode) from public, anon;
grant execute on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode) to authenticated;

create or replace function public.generate_kuri_schedule_for_admin(target_kuri_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  kuri_row public.kuris%rowtype;
  current_cycle_id uuid;
  membership_count integer;
  custom_count integer;
  created_cycles integer := 0;
  v_cycle_start date;
  v_cycle_end date;
  v_due_date date;
  v_draw_date date;
  custom_row public.kuri_custom_cycle_schedules%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.* into kuri_row
  from public.kuris k
  where k.id = target_kuri_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update;

  if not found then
    raise exception 'You do not have permission to manage this Kuri.';
  end if;

  select count(*) into membership_count
  from public.memberships m
  where m.kuri_id = target_kuri_id;

  if membership_count = 0 then
    raise exception 'Add at least one membership before generating the schedule.';
  end if;

  if kuri_row.schedule_mode = 'CUSTOM'::public.kuri_schedule_mode then
    select count(*) into custom_count
    from public.kuri_custom_cycle_schedules s
    where s.kuri_id = target_kuri_id;

    if custom_count <> kuri_row.number_of_cycles then
      raise exception 'Custom schedule must define exactly % cycles before generation.', kuri_row.number_of_cycles;
    end if;

    if kuri_row.number_of_cycles > membership_count then
      raise exception 'Custom schedule cannot contain more cycles than current Kuri membership.';
    end if;
  end if;

  for i in 1..kuri_row.number_of_cycles loop
    if kuri_row.schedule_mode = 'CUSTOM'::public.kuri_schedule_mode then
      select s.* into custom_row
      from public.kuri_custom_cycle_schedules s
      where s.kuri_id = target_kuri_id
        and s.cycle_number = i;

      if not found then
        raise exception 'Custom schedule is missing cycle %.', i;
      end if;

      v_cycle_start := custom_row.period_start;
      v_cycle_end := custom_row.period_end;
      v_due_date := custom_row.due_date;
      v_draw_date := custom_row.draw_date;

    elsif kuri_row.frequency = 'WEEKLY'::public.kuri_frequency then
      v_cycle_start := (kuri_row.start_date + ((i-1) * interval '1 week'))::date;
      v_cycle_end := (v_cycle_start + interval '6 days')::date;
      v_due_date := v_cycle_start
        + ((kuri_row.due_day-1) * interval '1 day')
        - ((extract(isodow from v_cycle_start)::integer-1) * interval '1 day');
      v_draw_date := v_cycle_start
        + ((kuri_row.draw_day-1) * interval '1 day')
        - ((extract(isodow from v_cycle_start)::integer-1) * interval '1 day');

    elsif kuri_row.frequency = 'MONTHLY'::public.kuri_frequency then
      v_cycle_start := (kuri_row.start_date + ((i-1) * interval '1 month'))::date;
      v_cycle_end := (v_cycle_start + interval '1 month' - interval '1 day')::date;
      v_due_date := make_date(
        extract(year from v_cycle_start)::integer,
        extract(month from v_cycle_start)::integer,
        least(kuri_row.due_day,extract(day from v_cycle_end)::integer)
      );
      v_draw_date := make_date(
        extract(year from v_cycle_start)::integer,
        extract(month from v_cycle_start)::integer,
        least(kuri_row.draw_day,extract(day from v_cycle_end)::integer)
      );

    elsif kuri_row.frequency = 'YEARLY'::public.kuri_frequency then
      v_cycle_start := (kuri_row.start_date + ((i-1) * interval '1 year'))::date;
      v_cycle_end := (v_cycle_start + interval '1 year' - interval '1 day')::date;
      v_due_date := v_cycle_start
        + ((kuri_row.due_day-1) * interval '1 day');
      v_draw_date := v_cycle_start
        + ((kuri_row.draw_day-1) * interval '1 day');

      if v_due_date > v_cycle_end then
        v_due_date := v_cycle_end;
      end if;

      if v_draw_date > v_cycle_end then
        v_draw_date := v_cycle_end;
      end if;

    else
      raise exception 'Unsupported Kuri frequency.';
    end if;

    current_cycle_id := null;

    insert into public.cycles(
      kuri_id,cycle_number,period_start,period_end,due_date,draw_date,status
    )
    values(
      target_kuri_id,i,v_cycle_start,v_cycle_end,v_due_date,v_draw_date,'UPCOMING'
    )
    on conflict(kuri_id,cycle_number) do nothing
    returning id into current_cycle_id;

    if current_cycle_id is null then
      select c.id into current_cycle_id
      from public.cycles c
      where c.kuri_id=target_kuri_id and c.cycle_number=i;
    else
      created_cycles := created_cycles + 1;
    end if;

    insert into public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    select
      m.id,current_cycle_id,kuri_row.installment_amount,0,
      'UNPAID'::public.installment_status,c.due_date
    from public.memberships m
    join public.cycles c on c.id=current_cycle_id
    where m.kuri_id=target_kuri_id
      and c.status not in ('COMPLETED','CANCELLED')
    on conflict(membership_id,cycle_id) do nothing;
  end loop;

  perform public.sync_expense_obligations_for_kuri(target_kuri_id);
  return created_cycles;
end;
$function$;

revoke all on function public.generate_kuri_schedule_for_admin(uuid) from public, anon;
grant execute on function public.generate_kuri_schedule_for_admin(uuid) to authenticated;
