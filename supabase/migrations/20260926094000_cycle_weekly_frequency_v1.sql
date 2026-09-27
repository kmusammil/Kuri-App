-- CYCLE-003: Weekly frequency
-- Preserve the existing monthly creation API while adding an explicit
-- frequency-aware overload. For WEEKLY, due_day and draw_day mean ISO weekday
-- numbers (1=Monday ... 7=Sunday).

alter type public.kuri_frequency add value if not exists 'WEEKLY';

create or replace function public.generate_kuri_schedule_for_admin(target_kuri_id uuid)
returns integer
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  kuri_row public.kuris%rowtype;
  current_cycle_id uuid;
  membership_count integer;
  created_cycles integer := 0;
  v_cycle_start date;
  v_cycle_end date;
  v_due_date date;
  v_draw_date date;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.* into kuri_row
  from public.kuris k
  where k.id = target_kuri_id
    and public.has_kuri_admin_role(k.id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
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

  for i in 1..kuri_row.number_of_cycles loop
    if kuri_row.frequency = 'WEEKLY'::public.kuri_frequency then
      v_cycle_start := (kuri_row.start_date + ((i-1) * interval '1 week'))::date;
      v_cycle_end := (v_cycle_start + interval '6 days')::date;

      v_due_date := v_cycle_start + ((kuri_row.due_day - 1) * interval '1 day')::date
        - ((extract(isodow from v_cycle_start)::integer - 1) * interval '1 day')::date;

      v_draw_date := v_cycle_start + ((kuri_row.draw_day - 1) * interval '1 day')::date
        - ((extract(isodow from v_cycle_start)::integer - 1) * interval '1 day')::date;
    else
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
    select m.id,current_cycle_id,kuri_row.installment_amount,0,
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

create or replace function public.create_kuri_for_admin(
  name text,
  description text default null,
  start_date date default null,
  number_of_cycles integer default null,
  membership_limit integer default null,
  installment_amount bigint default null,
  due_day integer default null,
  draw_day integer default null,
  gross_prize_amount bigint default null,
  muppu_amount bigint default 0,
  winner_rule text default 'ALL_PERSON_MEMBERSHIPS',
  exit_refund_rule public.refund_policy default 'AT_MATURITY'
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  organization_id uuid;
  kuri_id uuid;
  admin_org_count integer;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select count(distinct ou.organization_id) into admin_org_count
  from public.organization_users ou
  where ou.user_id=auth.uid()
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]);

  if admin_org_count=0 then
    raise exception 'You do not have permission to create a Kuri.';
  elsif admin_org_count>1 then
    raise exception 'Organization context is required to create a Kuri.';
  end if;

  select ou.organization_id into organization_id
  from public.organization_users ou
  where ou.user_id=auth.uid()
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by ou.organization_id::text limit 1;

  if nullif(trim(name),'') is null
     or start_date is null
     or number_of_cycles is null or number_of_cycles<=0
     or membership_limit is null or membership_limit<1 or membership_limit>1000
     or installment_amount is null or installment_amount<0
     or due_day is null or due_day<1 or due_day>31
     or draw_day is null or draw_day<1 or draw_day>31
     or gross_prize_amount is null or gross_prize_amount<0
     or muppu_amount is null or muppu_amount<0 then
    raise exception 'Please enter valid Kuri details.';
  end if;

  insert into public.kuris(
    organization_id,name,description,start_date,number_of_cycles,
    membership_limit,installment_amount,frequency,due_day,draw_day,
    gross_prize_amount,muppu_amount,winner_rule,exit_refund_rule,created_by
  )
  values(
    organization_id,trim(name),nullif(trim(description),''),
    start_date,number_of_cycles,membership_limit,installment_amount,
    'MONTHLY',due_day,draw_day,gross_prize_amount,muppu_amount,
    coalesce(nullif(trim(winner_rule),''),'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_rule,'AT_MATURITY'),auth.uid()
  )
  returning id into kuri_id;

  insert into public.kuri_admins(kuri_id,user_id,role)
  values(kuri_id,auth.uid(),'MAIN_ADMIN');

  return kuri_id;
end;
$function$;

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
  frequency_value public.kuri_frequency
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  organization_id uuid;
  kuri_id uuid;
  admin_org_count integer;
  max_day integer;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  if frequency_value is null then
    raise exception 'Frequency is required.';
  end if;

  max_day := case when frequency_value = 'WEEKLY'::public.kuri_frequency then 7 else 31 end;

  if nullif(trim(name),'') is null
     or start_date is null
     or number_of_cycles is null or number_of_cycles<=0
     or membership_limit is null or membership_limit<1 or membership_limit>1000
     or installment_amount is null or installment_amount<0
     or due_day is null or due_day<1 or due_day>max_day
     or draw_day is null or draw_day<1 or draw_day>max_day
     or gross_prize_amount is null or gross_prize_amount<0
     or muppu_amount is null or muppu_amount<0 then
    raise exception 'Please enter valid Kuri details.';
  end if;

  select count(distinct ou.organization_id) into admin_org_count
  from public.organization_users ou
  where ou.user_id=auth.uid()
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]);

  if admin_org_count=0 then
    raise exception 'You do not have permission to create a Kuri.';
  elsif admin_org_count>1 then
    raise exception 'Organization context is required to create a Kuri.';
  end if;

  select ou.organization_id into organization_id
  from public.organization_users ou
  where ou.user_id=auth.uid()
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by ou.organization_id::text limit 1;

  insert into public.kuris(
    organization_id,name,description,start_date,number_of_cycles,
    membership_limit,installment_amount,frequency,due_day,draw_day,
    gross_prize_amount,muppu_amount,winner_rule,exit_refund_rule,created_by
  )
  values(
    organization_id,trim(name),nullif(trim(description),''),
    start_date,number_of_cycles,membership_limit,installment_amount,
    frequency_value,due_day,draw_day,gross_prize_amount,muppu_amount,
    coalesce(nullif(trim(winner_rule),''),'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_rule,'AT_MATURITY'),auth.uid()
  )
  returning id into kuri_id;

  insert into public.kuri_admins(kuri_id,user_id,role)
  values(kuri_id,auth.uid(),'MAIN_ADMIN');

  return kuri_id;
end;
$function$;

revoke execute on function public.generate_kuri_schedule_for_admin(uuid) from public,anon;
grant execute on function public.generate_kuri_schedule_for_admin(uuid) to authenticated;

revoke execute on function public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy
) from public,anon;
grant execute on function public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy
) to authenticated;

revoke execute on function public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency
) from public,anon;
grant execute on function public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy,public.kuri_frequency
) to authenticated;
