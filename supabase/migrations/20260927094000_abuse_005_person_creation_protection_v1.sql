-- ABUSE-005: Membership/person creation protection
-- Extend the existing creation-volume controls to organization person creation.
-- Membership creation already has per-Kuri/per-actor 10-minute and hourly limits.

begin;

alter table public.system_capacity_limits
  add column if not exists person_creations_per_10_minutes integer not null default 20
    check (person_creations_per_10_minutes > 0),
  add column if not exists person_creations_per_hour integer not null default 100
    check (person_creations_per_hour > 0);

create table if not exists public.organization_person_creation_rate_limits (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_user_id uuid not null references public.users(id) on delete cascade,
  window_10m_started_at timestamptz not null default now(),
  window_10m_count integer not null default 0 check (window_10m_count >= 0),
  window_hour_started_at timestamptz not null default now(),
  window_hour_count integer not null default 0 check (window_hour_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (organization_id, actor_user_id)
);

alter table public.organization_person_creation_rate_limits enable row level security;

create or replace function public.enforce_person_creation_rate_limit(target_org_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_max_10m integer;
  v_max_hour integer;
  v_row public.organization_person_creation_rate_limits%rowtype;
  v_10m_count integer;
  v_hour_count integer;
begin
  if v_actor is null then
    raise exception 'You must be signed in.';
  end if;

  select person_creations_per_10_minutes, person_creations_per_hour
  into v_max_10m, v_max_hour
  from public.system_capacity_limits
  where id = true;

  if not found then
    raise exception 'System capacity configuration is missing';
  end if;

  insert into public.organization_person_creation_rate_limits
    (organization_id, actor_user_id, window_10m_started_at, window_10m_count,
     window_hour_started_at, window_hour_count, updated_at)
  values (target_org_id, v_actor, v_now, 0, v_now, 0, v_now)
  on conflict (organization_id, actor_user_id) do nothing;

  select *
  into v_row
  from public.organization_person_creation_rate_limits
  where organization_id = target_org_id
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
    raise exception 'Person creation rate limit exceeded. Try again later.';
  end if;

  if v_hour_count > v_max_hour then
    raise exception 'Person creation hourly limit exceeded. Try again later.';
  end if;

  update public.organization_person_creation_rate_limits
  set window_10m_started_at = v_row.window_10m_started_at,
      window_10m_count = v_10m_count,
      window_hour_started_at = v_row.window_hour_started_at,
      window_hour_count = v_hour_count,
      updated_at = v_now
  where organization_id = target_org_id
    and actor_user_id = v_actor;
end;
$function$;

revoke all on function public.enforce_person_creation_rate_limit(uuid) from public, anon, authenticated;

create or replace function public.create_person_for_org_admin(
  target_org_id uuid,
  registered_name text,
  display_name text default null,
  address text default null,
  notes text default null,
  phone text default null,
  email text default null
)
returns uuid
language plpgsql
security definer
set search_path = 'public'
as $function$
declare
  person_id uuid;
  clean_registered_name text := normalize(btrim(registered_name), NFC);
  clean_display_name text := nullif(normalize(btrim(display_name), NFC), '');
  clean_address text := nullif(btrim(address), '');
  clean_notes text := nullif(btrim(notes), '');
  clean_phone text := nullif(btrim(phone), '');
  clean_email text := nullif(btrim(email), '');
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if target_org_id is null then
    raise exception 'Organization is required.';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = target_org_id
      and ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to add people to this organization.';
  end if;

  if not public.is_valid_person_name(clean_registered_name) then
    raise exception 'Registered name must contain at least one Unicode letter and be between 1 and 200 characters.';
  end if;

  if clean_display_name is not null
     and not public.is_valid_person_name(clean_display_name) then
    raise exception 'Display name must contain at least one Unicode letter and be between 1 and 200 characters.';
  end if;

  perform public.enforce_person_creation_rate_limit(target_org_id);

  insert into public.people (
    organization_id, registered_name, display_name, address, notes
  )
  values (
    target_org_id, clean_registered_name, clean_display_name, clean_address, clean_notes
  )
  returning id into person_id;

  if clean_phone is not null then
    insert into public.person_phones (person_id, phone_number, is_primary)
    values (person_id, clean_phone, true);
  end if;

  if clean_email is not null then
    insert into public.person_emails (person_id, email, is_primary)
    values (person_id, clean_email, true);
  end if;

  return person_id;
end;
$function$;

revoke all on function public.create_person_for_org_admin(uuid,text,text,text,text,text,text) from public, anon;
grant execute on function public.create_person_for_org_admin(uuid,text,text,text,text,text,text) to authenticated;

commit;
