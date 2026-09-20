begin;

-- Admin-only RPCs for the organization-scoped Kuri registry.
create or replace function public.list_kuris_for_admin()
returns table (
  id uuid,
  name text,
  description text,
  start_date date,
  number_of_cycles integer,
  membership_limit integer,
  installment_amount bigint,
  gross_prize_amount bigint,
  status public.kuri_status
)
language sql
security definer
set search_path = public
stable
as $$
  select
    k.id,
    k.name,
    k.description,
    k.start_date,
    k.number_of_cycles,
    k.membership_limit,
    k.installment_amount,
    k.gross_prize_amount,
    k.status
  from public.kuris k
  where exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and ou.organization_id = k.organization_id
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
  order by k.created_at desc;
$$;

create or replace function public.get_kuri_for_admin(target_kuri_id uuid)
returns table (
  id uuid,
  name text,
  description text,
  start_date date,
  number_of_cycles integer,
  membership_limit integer,
  installment_amount bigint,
  frequency public.kuri_frequency,
  due_day integer,
  draw_day integer,
  gross_prize_amount bigint,
  muppu_amount bigint,
  winner_rule text,
  exit_refund_rule public.refund_policy,
  status public.kuri_status
)
language sql
security definer
set search_path = public
stable
as $$
  select
    k.id,
    k.name,
    k.description,
    k.start_date,
    k.number_of_cycles,
    k.membership_limit,
    k.installment_amount,
    k.frequency,
    k.due_day,
    k.draw_day,
    k.gross_prize_amount,
    k.muppu_amount,
    k.winner_rule,
    k.exit_refund_rule,
    k.status
  from public.kuris k
  where k.id = target_kuri_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.user_id = auth.uid()
        and ou.organization_id = k.organization_id
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$$;

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
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select ou.organization_id
    into organization_id
  from public.organization_users ou
  where ou.user_id = auth.uid()
    and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by ou.created_at asc
  limit 1;

  if organization_id is null then
    raise exception 'You do not have permission to create a Kuri.';
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
    exit_refund_rule
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
    coalesce(exit_refund_rule, 'AT_MATURITY')
  )
  returning id into kuri_id;

  return kuri_id;
end;
$$;

revoke all on function public.list_kuris_for_admin() from public;
revoke all on function public.get_kuri_for_admin(uuid) from public;
revoke all on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) from public;

grant execute on function public.list_kuris_for_admin() to authenticated;
grant execute on function public.get_kuri_for_admin(uuid) to authenticated;
grant execute on function public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) to authenticated;

commit;
