-- SEC-002: centralized practical capacity limits
-- Canonical limits: 250 members/Kuri, 36 cycles/Kuri, 10 Kuris/organization.

create table if not exists public.system_capacity_limits (
  id boolean primary key default true check (id),
  max_members_per_kuri integer not null check (max_members_per_kuri > 0),
  max_cycles_per_kuri integer not null check (max_cycles_per_kuri > 0),
  max_kuris_per_organization integer not null check (max_kuris_per_organization > 0),
  updated_at timestamptz not null default now()
);

alter table public.system_capacity_limits enable row level security;
revoke all on table public.system_capacity_limits from public, anon, authenticated;

insert into public.system_capacity_limits (id, max_members_per_kuri, max_cycles_per_kuri, max_kuris_per_organization)
values (true, 250, 36, 10)
on conflict (id) do update
set max_members_per_kuri = excluded.max_members_per_kuri,
    max_cycles_per_kuri = excluded.max_cycles_per_kuri,
    max_kuris_per_organization = excluded.max_kuris_per_organization,
    updated_at = now();

alter table public.kuris drop constraint if exists kuris_membership_limit_max_1000;

create or replace function public.enforce_system_capacity_limits()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max_members integer;
  v_max_cycles integer;
  v_max_kuris integer;
  v_kuri_count integer;
begin
  select max_members_per_kuri, max_cycles_per_kuri, max_kuris_per_organization
  into v_max_members, v_max_cycles, v_max_kuris
  from public.system_capacity_limits
  where id = true;

  if not found then
    raise exception 'System capacity configuration is missing';
  end if;

  if new.membership_limit > v_max_members then
    raise exception 'Kuri membership limit % exceeds system maximum %', new.membership_limit, v_max_members
      using errcode = '22023';
  end if;

  if new.number_of_cycles > v_max_cycles then
    raise exception 'Kuri cycle count % exceeds system maximum %', new.number_of_cycles, v_max_cycles
      using errcode = '22023';
  end if;

  if tg_op = 'INSERT' or new.organization_id is distinct from old.organization_id then
    select count(*) into v_kuri_count
    from public.kuris k
    where k.organization_id = new.organization_id
      and k.id is distinct from new.id;

    if v_kuri_count >= v_max_kuris then
      raise exception 'Organization already has the maximum of % Kuris', v_max_kuris
        using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_system_capacity_limits on public.kuris;

create trigger enforce_system_capacity_limits
before insert or update of organization_id, membership_limit, number_of_cycles
on public.kuris
for each row execute function public.enforce_system_capacity_limits();

revoke all on function public.enforce_system_capacity_limits() from public, anon, authenticated;

comment on table public.system_capacity_limits is
  'Single-source-of-truth system capacity limits. Values are changed here, not scattered through application logic.';
comment on column public.system_capacity_limits.max_members_per_kuri is
  'Maximum configured membership_limit for one Kuri. Current practical ceiling: 250.';
comment on column public.system_capacity_limits.max_cycles_per_kuri is
  'Maximum configured number_of_cycles for one Kuri. Current practical ceiling: 36.';
comment on column public.system_capacity_limits.max_kuris_per_organization is
  'Maximum Kuris belonging to one organization. Current practical ceiling: 10.';
