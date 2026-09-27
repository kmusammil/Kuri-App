begin;

-- Reconcile core Kuri-scoped reads and membership creation with Kuri authority.
-- Organization-level authority remains separate.

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
  where public.has_kuri_admin_role(
    k.id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
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
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );
$$;

create or replace function public.list_memberships_for_admin(target_kuri_id uuid)
returns table (
  id uuid,
  kuri_id uuid,
  person_id uuid,
  membership_number text,
  status public.membership_status,
  joined_at timestamptz,
  registered_name text,
  display_name text
)
language sql
security definer
set search_path = public
stable
as $$
  select
    m.id,
    m.kuri_id,
    m.person_id,
    m.membership_number,
    m.status,
    m.joined_at,
    p.registered_name,
    p.display_name
  from public.memberships m
  join public.people p on p.id = m.person_id
  join public.kuris k on k.id = m.kuri_id
  where m.kuri_id = target_kuri_id
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by m.membership_number;
$$;

create or replace function public.list_people_available_for_membership(target_kuri_id uuid)
returns table (
  id uuid,
  registered_name text,
  display_name text
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id,p.registered_name,p.display_name
  from public.people p
  join public.kuris k on k.organization_id = p.organization_id
  where k.id = target_kuri_id
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by coalesce(nullif(p.display_name,''),p.registered_name),p.registered_name;
$$;

create or replace function public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  target_membership_number text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  membership_id_value uuid;
  target_org_id uuid;
  target_kuri_status public.kuri_status;
  target_limit integer;
  current_membership_count integer;
  cycle_row record;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.organization_id,k.status,k.membership_limit
  into target_org_id,target_kuri_status,target_limit
  from public.kuris k
  where k.id=target_kuri_id
  for update;

  if target_org_id is null then
    raise exception 'Kuri not found.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to add memberships.';
  end if;

  if target_kuri_status not in ('OPEN','ACTIVE') then
    raise exception 'Memberships can only be added to an OPEN or ACTIVE Kuri.';
  end if;

  if not exists (
    select 1
    from public.people p
    where p.id=target_person_id
      and p.organization_id=target_org_id
  ) then
    raise exception 'Person not found in this organization.';
  end if;

  select count(*) into current_membership_count
  from public.memberships m
  where m.kuri_id=target_kuri_id;

  if current_membership_count >= target_limit then
    raise exception 'Kuri membership limit has been reached.';
  end if;

  insert into public.memberships(kuri_id,person_id,membership_number,status)
  values(
    target_kuri_id,
    target_person_id,
    nullif(btrim(target_membership_number),''),
    'ACTIVE'
  )
  returning id into membership_id_value;

  for cycle_row in
    select id,due_date
    from public.cycles
    where kuri_id=target_kuri_id
    order by cycle_number
  loop
    insert into public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    select
      membership_id_value,
      cycle_row.id,
      k.installment_amount,
      0,
      'UNPAID'::public.installment_status,
      cycle_row.due_date
    from public.kuris k
    where k.id=target_kuri_id
    on conflict (membership_id,cycle_id) do nothing;
  end loop;

  return membership_id_value;
end;
$$;

create or replace function public.list_cycles_for_admin(target_kuri_id uuid)
returns table (
  id uuid,
  cycle_number integer,
  period_start date,
  period_end date,
  due_date date,
  draw_date date,
  status public.cycle_status,
  installment_count bigint,
  paid_installment_count bigint
)
language sql
security definer
set search_path = public
stable
as $$
  select
    c.id,
    c.cycle_number,
    c.period_start,
    c.period_end,
    c.due_date,
    c.draw_date,
    c.status,
    count(i.id) as installment_count,
    count(i.id) filter (where i.status in ('PAID','PAID_LATE')) as paid_installment_count
  from public.cycles c
  join public.kuris k on k.id = c.kuri_id
  left join public.installments i on i.cycle_id = c.id
  where c.kuri_id = target_kuri_id
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  group by
    c.id,
    c.cycle_number,
    c.period_start,
    c.period_end,
    c.due_date,
    c.draw_date,
    c.status
  order by c.cycle_number;
$$;

create or replace function public.get_cycle_for_admin(target_cycle_id uuid)
returns table (
  id uuid,
  kuri_id uuid,
  cycle_number integer,
  period_start date,
  period_end date,
  due_date date,
  draw_date date,
  status public.cycle_status
)
language sql
stable
security definer
set search_path = public
as $$
  select
    c.id,
    c.kuri_id,
    c.cycle_number,
    c.period_start,
    c.period_end,
    c.due_date,
    c.draw_date,
    c.status
  from public.cycles c
  join public.kuris k on k.id = c.kuri_id
  where c.id = target_cycle_id
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );
$$;

commit;
