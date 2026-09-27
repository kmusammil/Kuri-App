-- SEC-002 hardening: serialize organization-level Kuri capacity checks.
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
    perform 1
    from public.organizations o
    where o.id = new.organization_id
    for update;

    if not found then
      raise exception 'Organization % does not exist', new.organization_id
        using errcode = '23503';
    end if;

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

revoke all on function public.enforce_system_capacity_limits() from public, anon, authenticated;
