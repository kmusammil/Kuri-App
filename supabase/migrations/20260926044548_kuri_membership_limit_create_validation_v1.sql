begin;

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
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  select count(distinct ou.organization_id)
    into admin_org_count
  from public.organization_users ou
  where ou.user_id=(select auth.uid())
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]);

  if admin_org_count=0 then
    raise exception 'You do not have permission to create a Kuri.';
  elsif admin_org_count>1 then
    raise exception 'Organization context is required to create a Kuri.';
  end if;

  select ou.organization_id
    into organization_id
  from public.organization_users ou
  where ou.user_id=(select auth.uid())
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by ou.organization_id::text
  limit 1;

  if nullif(trim(name), '') is null
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
    organization_id,
    trim(name),
    nullif(trim(description),''),
    start_date,
    number_of_cycles,
    membership_limit,
    installment_amount,
    'MONTHLY',
    due_day,
    draw_day,
    gross_prize_amount,
    muppu_amount,
    coalesce(nullif(trim(winner_rule),''),'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_rule,'AT_MATURITY'),
    (select auth.uid())
  )
  returning id into kuri_id;

  insert into public.kuri_admins(kuri_id,user_id,role)
  values(kuri_id,(select auth.uid()),'MAIN_ADMIN');

  return kuri_id;
end;
$function$;

create or replace function public.create_kuri_for_organization_admin(
  target_organization_id uuid,
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
  kuri_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  if target_organization_id is null then
    raise exception 'Organization context is required.';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = target_organization_id
      and ou.user_id = (select auth.uid())
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to create a Kuri in this organization.';
  end if;

  if nullif(trim(name), '') is null
    or start_date is null
    or number_of_cycles is null or number_of_cycles <= 0
    or membership_limit is null or membership_limit < 1 or membership_limit > 1000
    or installment_amount is null or installment_amount < 0
    or due_day is null or due_day < 1 or due_day > 31
    or draw_day is null or draw_day < 1 or draw_day > 31
    or gross_prize_amount is null or gross_prize_amount < 0
    or muppu_amount is null or muppu_amount < 0 then
    raise exception 'Please enter valid Kuri details.';
  end if;

  insert into public.kuris (
    organization_id,name,description,start_date,number_of_cycles,
    membership_limit,installment_amount,frequency,due_day,draw_day,
    gross_prize_amount,muppu_amount,winner_rule,exit_refund_rule,created_by
  )
  values (
    target_organization_id,
    trim(name),
    nullif(trim(description), ''),
    start_date,
    number_of_cycles,
    membership_limit,
    installment_amount,
    'MONTHLY',
    due_day,
    draw_day,
    gross_prize_amount,
    muppu_amount,
    coalesce(nullif(trim(winner_rule), ''), 'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_rule, 'AT_MATURITY'),
    (select auth.uid())
  )
  returning id into kuri_id;

  insert into public.kuri_admins (kuri_id,user_id,role)
  values (kuri_id,(select auth.uid()),'MAIN_ADMIN');

  return kuri_id;
end;
$function$;

revoke execute on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) from public, anon;
grant execute on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) to authenticated;

revoke execute on function public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) from public, anon;
grant execute on function public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) to authenticated;

commit;