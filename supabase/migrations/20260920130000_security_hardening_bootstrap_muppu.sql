begin;

-- Security hardening:
-- 1) Prevent bootstrap_kuri_admin from promoting an arbitrary existing
--    organization member to MAIN_ADMIN.
-- 2) Ensure Muppu records cannot link a person from another organization.

create or replace function public.bootstrap_kuri_admin(
  target_organization_name text default 'Kuri-App'
)
returns uuid
language plpgsql
security definer
set search_path=''
as $function$
declare
  current_user_id uuid := (select auth.uid());
  organization_id uuid;
  membership_count integer;
begin
  if current_user_id is null then
    raise exception 'You must be signed in to bootstrap the Kuri-App workspace.';
  end if;

  if not exists (
    select 1 from public.users where id = current_user_id
  ) then
    raise exception 'The signed-in Auth user does not have an application user record.';
  end if;

  select count(*) into membership_count
  from public.organization_users;

  if membership_count > 0 then
    if not exists (
      select 1
      from public.organization_users ou
      where ou.user_id = current_user_id
        and ou.role = 'MAIN_ADMIN'
    ) then
      raise exception 'Bootstrap is only available to the existing MAIN_ADMIN when organization membership already exists.';
    end if;

    select ou.organization_id
      into organization_id
    from public.organization_users ou
    where ou.user_id = current_user_id
      and ou.role = 'MAIN_ADMIN'
    order by ou.created_at asc
    limit 1;

    if organization_id is null then
      raise exception 'MAIN_ADMIN organization membership not found.';
    end if;

    return organization_id;
  end if;

  if nullif(btrim(target_organization_name),'') is null then
    raise exception 'Organization name is required.';
  end if;

  insert into public.organizations (name)
  values (btrim(target_organization_name))
  returning id into organization_id;

  insert into public.organization_users (organization_id, user_id, role)
  values (organization_id, current_user_id, 'MAIN_ADMIN');

  return organization_id;
end;
$function$;

revoke all on function public.bootstrap_kuri_admin(text) from public, anon;
grant execute on function public.bootstrap_kuri_admin(text) to authenticated;

create or replace function public.create_muppu_record_for_admin(
  target_kuri_id uuid,
  target_cycle_id uuid,
  target_person_id uuid,
  target_amount bigint
)
returns uuid
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_org_id uuid;
  v_person_org_id uuid;
  v_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  if target_amount < 0 then
    raise exception 'Muppu amount cannot be negative.';
  end if;

  select k.organization_id
    into v_org_id
  from public.kuris k
  join public.cycles c
    on c.kuri_id=k.id
   and c.id=target_cycle_id
  where k.id=target_kuri_id;

  if v_org_id is null then
    raise exception 'Kuri or cycle not found.';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id=v_org_id
      and ou.user_id=(select auth.uid())
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to manage Muppu.';
  end if;

  select p.organization_id
    into v_person_org_id
  from public.people p
  where p.id=target_person_id;

  if v_person_org_id is null then
    raise exception 'Person not found.';
  end if;

  if v_person_org_id<>v_org_id then
    raise exception 'Person does not belong to this organization.';
  end if;

  insert into public.muppu_records(kuri_id,cycle_id,person_id,amount,status)
  values(target_kuri_id,target_cycle_id,target_person_id,target_amount,'UNPAID')
  returning id into v_id;

  return v_id;
end;
$function$;

revoke all on function public.create_muppu_record_for_admin(uuid,uuid,uuid,bigint) from public, anon;
grant execute on function public.create_muppu_record_for_admin(uuid,uuid,uuid,bigint) to authenticated;

commit;
