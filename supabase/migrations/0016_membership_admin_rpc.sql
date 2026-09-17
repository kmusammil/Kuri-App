begin;

-- Admin-only membership access. Memberships are organization-scoped through
-- their parent Kuri, so the RPCs resolve authorization without relying on
-- deep client-side RLS traversal.
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
    and exists (
      select 1
      from public.organization_users ou
      where ou.user_id = auth.uid()
        and ou.organization_id = k.organization_id
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
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
  select p.id, p.registered_name, p.display_name
  from public.people p
  where exists (
    select 1
    from public.kuris k
    join public.organization_users ou
      on ou.organization_id = k.organization_id
    where k.id = target_kuri_id
      and ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
  order by coalesce(nullif(p.display_name, ''), p.registered_name), p.registered_name;
$$;

create or replace function public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  membership_number text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  membership_id uuid;
  kuri_org_id uuid;
  clean_number text := nullif(trim(membership_number), '');
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.organization_id into kuri_org_id
  from public.kuris k
  join public.organization_users ou
    on ou.organization_id = k.organization_id
   and ou.user_id = auth.uid()
   and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  where k.id = target_kuri_id
  limit 1;

  if kuri_org_id is null then
    raise exception 'You do not have permission to add memberships to this Kuri.';
  end if;

  if target_person_id is null or not exists (
    select 1 from public.people p where p.id = target_person_id
  ) then
    raise exception 'Please select a valid person.';
  end if;

  if clean_number is null then
    raise exception 'Membership number is required.';
  end if;

  if exists (
    select 1
    from public.memberships m
    where m.kuri_id = target_kuri_id
      and m.membership_number = clean_number
  ) then
    raise exception 'That membership number is already used in this Kuri.';
  end if;

  if (
    select count(*) from public.memberships m where m.kuri_id = target_kuri_id
  ) >= (
    select k.membership_limit from public.kuris k where k.id = target_kuri_id
  ) then
    raise exception 'This Kuri has reached its membership limit.';
  end if;

  insert into public.memberships (kuri_id, person_id, membership_number, status)
  values (target_kuri_id, target_person_id, clean_number, 'ACTIVE')
  returning id into membership_id;

  return membership_id;
end;
$$;

revoke all on function public.list_memberships_for_admin(uuid) from public;
revoke all on function public.list_people_available_for_membership(uuid) from public;
revoke all on function public.create_membership_for_admin(uuid,uuid,text) from public;

grant execute on function public.list_memberships_for_admin(uuid) to authenticated;
grant execute on function public.list_people_available_for_membership(uuid) to authenticated;
grant execute on function public.create_membership_for_admin(uuid,uuid,text) to authenticated;

commit;
