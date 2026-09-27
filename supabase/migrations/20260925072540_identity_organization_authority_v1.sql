begin;

-- Foundation for explicit organization context and Kuri-scoped authority.
do $$
begin
  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='organization_type'
  ) then
    create type public.organization_type as enum ('PERSONAL','ORGANIZATION');
  end if;

  if not exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='kuri_admin_role'
  ) then
    create type public.kuri_admin_role as enum ('MAIN_ADMIN','ADMIN');
  end if;
end
$$;

alter table public.organizations
  add column if not exists org_type public.organization_type,
  add column if not exists created_by uuid references public.users(id) on delete set null;

alter table public.kuris
  add column if not exists created_by uuid references public.users(id) on delete set null;

create unique index if not exists organizations_personal_created_by_key
  on public.organizations(created_by)
  where org_type = 'PERSONAL';

create table if not exists public.kuri_admins (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role public.kuri_admin_role not null,
  created_at timestamptz not null default now(),
  unique (kuri_id, user_id)
);

create unique index if not exists kuri_admins_one_main_admin_key
  on public.kuri_admins(kuri_id)
  where role = 'MAIN_ADMIN';

alter table public.kuri_admins enable row level security;

drop policy if exists kuri_admins_select on public.kuri_admins;
create policy kuri_admins_select
  on public.kuri_admins
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.kuris k
      join public.organization_users ou
        on ou.organization_id = k.organization_id
      where k.id = kuri_admins.kuri_id
        and ou.user_id = (select auth.uid())
    )
  );

create or replace function public.has_kuri_admin_role(
  target_kuri uuid,
  target_roles public.kuri_admin_role[]
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.kuri_admins ka
    where ka.kuri_id = target_kuri
      and ka.user_id = (select auth.uid())
      and ka.role = any(target_roles)
  );
$$;

revoke all on function public.has_kuri_admin_role(uuid,public.kuri_admin_role[]) from public, anon;
grant execute on function public.has_kuri_admin_role(uuid,public.kuri_admin_role[]) to authenticated;

create or replace function public.list_my_organizations()
returns table (
  id uuid,
  name text,
  org_type public.organization_type,
  role public.app_role,
  created_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select o.id, o.name, o.org_type, ou.role, o.created_at
  from public.organization_users ou
  join public.organizations o on o.id = ou.organization_id
  where ou.user_id = (select auth.uid())
  order by o.created_at asc, o.id asc;
$$;

revoke all on function public.list_my_organizations() from public, anon;
grant execute on function public.list_my_organizations() to authenticated;

create or replace function public.get_organization_role(target_organization_id uuid)
returns public.app_role
language sql
security definer
set search_path = public
stable
as $$
  select ou.role
  from public.organization_users ou
  where ou.organization_id = target_organization_id
    and ou.user_id = (select auth.uid())
  limit 1;
$$;

revoke all on function public.get_organization_role(uuid) from public, anon;
grant execute on function public.get_organization_role(uuid) to authenticated;

create or replace function public.create_organization_for_user(
  organization_name text,
  target_org_type public.organization_type,
  organization_description text default null,
  organization_phone text default null,
  organization_email text default null,
  organization_address text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := (select auth.uid());
  organization_id uuid;
begin
  if current_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if not exists (select 1 from public.users where id = current_user_id) then
    raise exception 'Application user record not found.';
  end if;

  if nullif(trim(organization_name), '') is null or target_org_type is null then
    raise exception 'Organization name and type are required.';
  end if;

  if target_org_type = 'PERSONAL'
     and exists (
       select 1
       from public.organizations o
       where o.created_by = current_user_id
         and o.org_type = 'PERSONAL'
     ) then
    raise exception 'A personal organization already exists for this user.';
  end if;

  insert into public.organizations (
    name, org_type, created_by, description, phone, email, address
  )
  values (
    trim(organization_name),
    target_org_type,
    current_user_id,
    nullif(trim(organization_description), ''),
    nullif(trim(organization_phone), ''),
    nullif(trim(organization_email), ''),
    nullif(trim(organization_address), '')
  )
  returning id into organization_id;

  insert into public.organization_users (organization_id, user_id, role)
  values (organization_id, current_user_id, 'MAIN_ADMIN');

  return organization_id;
end;
$$;

revoke all on function public.create_organization_for_user(text,public.organization_type,text,text,text,text) from public, anon;
grant execute on function public.create_organization_for_user(text,public.organization_type,text,text,text,text) to authenticated;

-- Remove the "first organization wins" behavior from the legacy Kuri creator.
-- Existing single-organization users remain compatible; users with multiple
-- organizations must use the explicit-organization API below.
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
set search_path = public
as $$
declare
  organization_id uuid;
  kuri_id uuid;
  admin_org_count integer;
begin
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  select count(*), min(ou.organization_id)
    into admin_org_count, organization_id
  from public.organization_users ou
  where ou.user_id = (select auth.uid())
    and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[]);

  if admin_org_count = 0 then
    raise exception 'You do not have permission to create a Kuri.';
  elsif admin_org_count > 1 then
    raise exception 'Organization context is required to create a Kuri.';
  end if;

  if nullif(trim(name), '') is null
    or start_date is null
    or number_of_cycles is null or number_of_cycles <= 0
    or membership_limit is null or membership_limit <= 0
    or installment_amount is null or installment_amount < 0
    or due_day is null or due_day < 1 or due_day > 31
    or draw_day is null or draw_day < 1 or draw_day > 31
    or gross_prize_amount is null or gross_prize_amount < 0
    or muppu_amount is null or muppu_amount < 0 then
    raise exception 'Please enter valid Kuri details.';
  end if;

  insert into public.kuris (
    organization_id,
    name,
    description,
    start_date,
    number_of_cycles,
    membership_limit,
    installment_amount,
    frequency,
    due_day,
    draw_day,
    gross_prize_amount,
    muppu_amount,
    winner_rule,
    exit_refund_rule,
    created_by
  )
  values (
    organization_id,
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

  insert into public.kuri_admins (kuri_id, user_id, role)
  values (kuri_id, (select auth.uid()), 'MAIN_ADMIN');

  return kuri_id;
end;
$$;

revoke all on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) from public, anon;
grant execute on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) to authenticated;

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
set search_path = public
as $$
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
    or membership_limit is null or membership_limit <= 0
    or installment_amount is null or installment_amount < 0
    or due_day is null or due_day < 1 or due_day > 31
    or draw_day is null or draw_day < 1 or draw_day > 31
    or gross_prize_amount is null or gross_prize_amount < 0
    or muppu_amount is null or muppu_amount < 0 then
    raise exception 'Please enter valid Kuri details.';
  end if;

  insert into public.kuris (
    organization_id,
    name,
    description,
    start_date,
    number_of_cycles,
    membership_limit,
    installment_amount,
    frequency,
    due_day,
    draw_day,
    gross_prize_amount,
    muppu_amount,
    winner_rule,
    exit_refund_rule,
    created_by
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

  insert into public.kuri_admins (kuri_id, user_id, role)
  values (kuri_id, (select auth.uid()), 'MAIN_ADMIN');

  return kuri_id;
end;
$$;

revoke all on function public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) from public, anon;
grant execute on function public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) to authenticated;

commit;
