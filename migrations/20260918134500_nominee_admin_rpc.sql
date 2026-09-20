begin;

create or replace function public.list_nominees_for_admin(target_person_id uuid)
returns table (
  id uuid,
  person_id uuid,
  name text,
  relationship text,
  phone text,
  address text,
  notes text
)
language sql
security definer
set search_path=public
stable
as $$
  select n.id,n.person_id,n.name,n.relationship,n.phone,n.address,n.notes
  from public.nominees n
  where n.person_id=target_person_id
    and exists (
      select 1
      from public.memberships m
      join public.kuris k on k.id=m.kuri_id
      join public.organization_users ou
        on ou.organization_id=k.organization_id
       and ou.user_id=auth.uid()
      where m.person_id=target_person_id
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  order by n.name,n.id;
$$;

create or replace function public.create_nominee_for_admin(
  target_person_id uuid,
  nominee_name text,
  nominee_relationship text default null,
  nominee_phone text default null,
  nominee_address text default null,
  nominee_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  nominee_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if nullif(btrim(nominee_name),'') is null then
    raise exception 'Nominee name is required.';
  end if;

  if not exists (
    select 1
    from public.memberships m
    join public.kuris k on k.id=m.kuri_id
    join public.organization_users ou
      on ou.organization_id=k.organization_id
     and ou.user_id=auth.uid()
     and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    where m.person_id=target_person_id
  ) then
    raise exception 'Person not found or access denied.';
  end if;

  insert into public.nominees(person_id,name,relationship,phone,address,notes)
  values(
    target_person_id,
    nullif(btrim(nominee_name),''),
    nullif(btrim(nominee_relationship),''),
    nullif(btrim(nominee_phone),''),
    nullif(btrim(nominee_address),''),
    nullif(btrim(nominee_notes),'')
  )
  returning id into nominee_id;

  return nominee_id;
end;
$$;

create or replace function public.update_nominee_for_admin(
  target_nominee_id uuid,
  nominee_name text,
  nominee_relationship text default null,
  nominee_phone text default null,
  nominee_address text default null,
  nominee_notes text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if nullif(btrim(nominee_name),'') is null then raise exception 'Nominee name is required.'; end if;

  if not exists (
    select 1
    from public.nominees n
    join public.memberships m on m.person_id=n.person_id
    join public.kuris k on k.id=m.kuri_id
    join public.organization_users ou
      on ou.organization_id=k.organization_id
     and ou.user_id=auth.uid()
     and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    where n.id=target_nominee_id
  ) then
    raise exception 'Nominee not found or access denied.';
  end if;

  update public.nominees
  set name=nullif(btrim(nominee_name),''),
      relationship=nullif(btrim(nominee_relationship),''),
      phone=nullif(btrim(nominee_phone),''),
      address=nullif(btrim(nominee_address),''),
      notes=nullif(btrim(nominee_notes),'')
  where id=target_nominee_id;
end;
$$;

create or replace function public.delete_nominee_for_admin(target_nominee_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  if not exists (
    select 1
    from public.nominees n
    join public.memberships m on m.person_id=n.person_id
    join public.kuris k on k.id=m.kuri_id
    join public.organization_users ou
      on ou.organization_id=k.organization_id
     and ou.user_id=auth.uid()
     and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    where n.id=target_nominee_id
  ) then
    raise exception 'Nominee not found or access denied.';
  end if;

  delete from public.nominees where id=target_nominee_id;
end;
$$;

revoke all on function public.list_nominees_for_admin(uuid) from public;
revoke all on function public.create_nominee_for_admin(uuid,text,text,text,text,text) from public;
revoke all on function public.update_nominee_for_admin(uuid,text,text,text,text,text) from public;
revoke all on function public.delete_nominee_for_admin(uuid) from public;

grant execute on function public.list_nominees_for_admin(uuid) to authenticated;
grant execute on function public.create_nominee_for_admin(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.update_nominee_for_admin(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.delete_nominee_for_admin(uuid) to authenticated;

commit;