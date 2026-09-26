-- SEC-003: centralized membership-creation rate protection.
-- Current policy: 20 memberships / 10 minutes and 100 / hour,
-- per authenticated actor and Kuri. Change the two values here only.

alter table public.system_capacity_limits
  add column if not exists membership_creations_per_10_minutes integer not null default 20,
  add column if not exists membership_creations_per_hour integer not null default 100;

alter table public.system_capacity_limits
  drop constraint if exists system_capacity_limits_membership_rate_check;

alter table public.system_capacity_limits
  add constraint system_capacity_limits_membership_rate_check
  check (
    membership_creations_per_10_minutes > 0
    and membership_creations_per_hour >= membership_creations_per_10_minutes
  );

update public.system_capacity_limits
set membership_creations_per_10_minutes = 20,
    membership_creations_per_hour = 100,
    updated_at = now()
where id = true;

create table if not exists public.kuri_membership_creation_rate_limits (
  kuri_id uuid not null references public.kuris(id) on delete cascade,
  actor_user_id uuid not null references auth.users(id) on delete cascade,
  window_10m_started_at timestamptz not null default now(),
  window_10m_count integer not null default 0 check (window_10m_count >= 0),
  window_hour_started_at timestamptz not null default now(),
  window_hour_count integer not null default 0 check (window_hour_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (kuri_id, actor_user_id)
);

alter table public.kuri_membership_creation_rate_limits enable row level security;
revoke all on table public.kuri_membership_creation_rate_limits from public, anon, authenticated;

create or replace function public.enforce_membership_creation_rate_limit(target_kuri_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_max_10m integer;
  v_max_hour integer;
  v_row public.kuri_membership_creation_rate_limits%rowtype;
  v_10m_count integer;
  v_hour_count integer;
begin
  if v_actor is null then
    raise exception 'You must be signed in.';
  end if;

  select membership_creations_per_10_minutes, membership_creations_per_hour
  into v_max_10m, v_max_hour
  from public.system_capacity_limits
  where id = true;

  if not found then
    raise exception 'System capacity configuration is missing';
  end if;

  insert into public.kuri_membership_creation_rate_limits (
    kuri_id, actor_user_id, window_10m_started_at, window_10m_count,
    window_hour_started_at, window_hour_count, updated_at
  )
  values (target_kuri_id, v_actor, v_now, 0, v_now, 0, v_now)
  on conflict (kuri_id, actor_user_id) do nothing;

  select *
  into v_row
  from public.kuri_membership_creation_rate_limits
  where kuri_id = target_kuri_id
    and actor_user_id = v_actor
  for update;

  if v_now >= v_row.window_10m_started_at + interval '10 minutes' then
    v_row.window_10m_started_at := v_now;
    v_row.window_10m_count := 0;
  end if;

  if v_now >= v_row.window_hour_started_at + interval '1 hour' then
    v_row.window_hour_started_at := v_now;
    v_row.window_hour_count := 0;
  end if;

  v_10m_count := v_row.window_10m_count + 1;
  v_hour_count := v_row.window_hour_count + 1;

  if v_10m_count > v_max_10m then
    raise exception 'Membership creation rate limit exceeded. Try again later.'
      using errcode = 'P0001';
  end if;

  if v_hour_count > v_max_hour then
    raise exception 'Membership creation hourly limit exceeded. Try again later.'
      using errcode = 'P0001';
  end if;

  update public.kuri_membership_creation_rate_limits
  set window_10m_started_at = v_row.window_10m_started_at,
      window_10m_count = v_10m_count,
      window_hour_started_at = v_row.window_hour_started_at,
      window_hour_count = v_hour_count,
      updated_at = v_now
  where kuri_id = target_kuri_id
    and actor_user_id = v_actor;
end;
$$;

revoke all on function public.enforce_membership_creation_rate_limit(uuid)
from public, anon, authenticated;

create or replace function public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  target_membership_number text,
  p_catch_up_policy text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership_id_value uuid;
  target_org_id uuid;
  target_kuri_status public.kuri_status;
  target_enrollment_closed_at timestamptz;
  target_limit integer;
  current_membership_count integer;
  cycle_row record;
  person_exists boolean;
  normalized_catch_up_policy text := upper(coalesce(nullif(btrim(p_catch_up_policy), ''), 'NONE'));
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if normalized_catch_up_policy not in ('NONE','FULL') then
    raise exception 'Invalid catch-up policy. Use NONE or FULL.';
  end if;

  select k.organization_id,k.status,k.enrollment_closed_at,k.membership_limit
    into target_org_id,target_kuri_status,target_enrollment_closed_at,target_limit
  from public.kuris k
  where k.id=target_kuri_id
  for update;

  if target_org_id is null then
    raise exception 'Kuri not found.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to add memberships.';
  end if;

  if target_kuri_status not in ('OPEN','ACTIVE') then
    raise exception 'Memberships can only be added to an OPEN or ACTIVE Kuri.';
  end if;

  if target_enrollment_closed_at is not null then
    raise exception 'Kuri enrollment is closed; new memberships cannot be added.';
  end if;

  select exists(
    select 1
    from public.people p
    where p.id=target_person_id
      and p.organization_id=target_org_id
  ) into person_exists;

  if not person_exists then
    raise exception 'Person not found in this organization.';
  end if;

  select count(*) into current_membership_count
  from public.memberships m
  where m.kuri_id=target_kuri_id;

  if current_membership_count>=target_limit then
    raise exception 'Kuri membership limit has been reached.';
  end if;

  perform public.enforce_membership_creation_rate_limit(target_kuri_id);

  insert into public.memberships(
    kuri_id,person_id,membership_number,status,catch_up_policy
  )
  values(
    target_kuri_id,
    target_person_id,
    nullif(btrim(target_membership_number),''),
    'ACTIVE',
    normalized_catch_up_policy
  )
  returning id into membership_id_value;

  for cycle_row in
    select c.id,c.due_date,c.status
    from public.cycles c
    where c.kuri_id=target_kuri_id
      and (
        normalized_catch_up_policy='FULL'
        or c.status not in ('COMPLETED','CANCELLED')
      )
      and c.status <> 'CANCELLED'
    order by c.cycle_number
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
    on conflict(membership_id,cycle_id) do nothing;
  end loop;

  perform public.sync_expense_obligations_for_membership(membership_id_value);

  return membership_id_value;
end;
$$;

revoke all on function public.create_membership_for_admin(uuid,uuid,text,p_catch_up_policy)
from public, anon;
grant execute on function public.create_membership_for_admin(uuid,uuid,text,p_catch_up_policy) to authenticated;

comment on column public.system_capacity_limits.membership_creations_per_10_minutes is
  'Maximum membership creations by one actor in one Kuri during a rolling 10-minute window.';
comment on column public.system_capacity_limits.membership_creations_per_hour is
  'Maximum membership creations by one actor in one Kuri during a rolling one-hour window.';
