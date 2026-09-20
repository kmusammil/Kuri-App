-- People / membership tenancy hardening
-- Scope person records to an organization and close cross-tenant admin read paths.

alter table public.people
  add column if not exists organization_id uuid;

do $$
declare
  unresolved_count integer;
  org_count integer;
begin
  select count(*) into unresolved_count
  from public.people p
  where not exists (
    select 1
    from public.memberships m
    join public.kuris k on k.id = m.kuri_id
    where m.person_id = p.id
  );

  select count(*) into org_count from public.organizations;

  if unresolved_count > 0 and org_count <> 1 then
    raise exception 'Cannot safely backfill people.organization_id: % people have no membership and the database has % organizations.', unresolved_count, org_count;
  end if;

  update public.people p
  set organization_id = x.organization_id
  from (
    select m.person_id, (array_agg(k.organization_id))[1] as organization_id
    from public.memberships m
    join public.kuris k on k.id = m.kuri_id
    group by m.person_id
    having count(distinct k.organization_id) = 1
  ) x
  where p.id = x.person_id
    and p.organization_id is null;

  if unresolved_count > 0 then
    update public.people
    set organization_id = (select (array_agg(id))[1] from public.organizations)
    where organization_id is null;
  end if;
end $$;

alter table public.people
  alter column organization_id set not null;

alter table public.people
  drop constraint if exists people_organization_id_fkey;

alter table public.people
  add constraint people_organization_id_fkey
  foreign key (organization_id) references public.organizations(id) on delete restrict;

create index if not exists people_organization_id_idx
  on public.people (organization_id);

-- Replace broad people policies with organization-scoped policies.
drop policy if exists people_admin_delete on public.people;
drop policy if exists people_admin_insert on public.people;
drop policy if exists people_admin_select on public.people;
drop policy if exists people_admin_update on public.people;
drop policy if exists people_select on public.people;

create policy people_select
on public.people
for select
to public
using (
  (exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = people.organization_id
      and ou.user_id = auth.uid()
  ))
  or
  (exists (
    select 1
    from public.users u
    where u.id = auth.uid()
      and u.person_id = people.id
  ))
);

create policy people_admin_insert
on public.people
for insert
to public
with check (
  public.has_org_role(
    people.organization_id,
    array['MAIN_ADMIN','ADMIN']::public.app_role[]
  )
);

create policy people_admin_update
on public.people
for update
to public
using (
  public.has_org_role(
    people.organization_id,
    array['MAIN_ADMIN','ADMIN']::public.app_role[]
  )
)
with check (
  public.has_org_role(
    people.organization_id,
    array['MAIN_ADMIN','ADMIN']::public.app_role[]
  )
);

create policy people_admin_delete
on public.people
for delete
to public
using (
  public.has_org_role(
    people.organization_id,
    array['MAIN_ADMIN','ADMIN']::public.app_role[]
  )
);

-- Explicit org-scoped person creation API.
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
set search_path to 'public'
as $function$
declare
  person_id uuid;
  clean_registered_name text := nullif(trim(registered_name), '');
  clean_display_name text := nullif(trim(display_name), '');
  clean_address text := nullif(trim(address), '');
  clean_notes text := nullif(trim(notes), '');
  clean_phone text := nullif(trim(phone), '');
  clean_email text := nullif(trim(email), '');
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

  if clean_registered_name is null then
    raise exception 'Registered name is required.';
  end if;

  insert into public.people (
    organization_id,
    registered_name,
    display_name,
    address,
    notes
  )
  values (
    target_org_id,
    clean_registered_name,
    clean_display_name,
    clean_address,
    clean_notes
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

-- Keep the existing RPC safe for the current one-org case; reject ambiguity.
create or replace function public.create_person_for_admin(
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
set search_path to 'public'
as $function$
declare
  target_org_id uuid;
begin
  select (array_agg(ou.organization_id))[1]
  into target_org_id
  from public.organization_users ou
  where ou.user_id = auth.uid()
    and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[]);

  if target_org_id is null then
    raise exception 'You do not have permission to add people.';
  end if;

  if (
    select count(*)
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) > 1 then
    raise exception 'This administrator belongs to multiple organizations. Use create_person_for_org_admin.';
  end if;

  return public.create_person_for_org_admin(
    target_org_id,
    registered_name,
    display_name,
    address,
    notes,
    phone,
    email
  );
end;
$function$;

drop function if exists public.list_people_for_admin();
drop function if exists public.get_person_for_admin(uuid);

-- Scope person list/detail APIs to organizations administered by the caller.
create or replace function public.list_people_for_admin()
returns table(
  id uuid,
  organization_id uuid,
  registered_name text,
  display_name text,
  address text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id,p.organization_id,p.registered_name,p.display_name,p.address,p.created_at
  from public.people p
  where exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = p.organization_id
      and ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
  order by p.created_at desc;
$function$;

create or replace function public.get_person_for_admin(target_person_id uuid)
returns table(
  id uuid,
  organization_id uuid,
  registered_name text,
  display_name text,
  address text,
  notes text,
  created_at timestamptz,
  phones jsonb,
  emails jsonb
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select
    p.id,
    p.organization_id,
    p.registered_name,
    p.display_name,
    p.address,
    p.notes,
    p.created_at,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', pp.id,
            'phone_number', pp.phone_number,
            'label', pp.label,
            'is_primary', pp.is_primary
          ) order by pp.is_primary desc, pp.id
        )
        from public.person_phones pp
        where pp.person_id = p.id
      ),
      '[]'::jsonb
    ),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', pe.id,
            'email', pe.email,
            'label', pe.label,
            'is_primary', pe.is_primary
          ) order by pe.is_primary desc, pe.id
        )
        from public.person_emails pe
        where pe.person_id = p.id
      ),
      '[]'::jsonb
    )
  from public.people p
  where p.id = target_person_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id = p.organization_id
        and ou.user_id = auth.uid()
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$function$;

-- Only people belonging to the Kuri's organization are eligible for selection.
create or replace function public.list_people_available_for_membership(target_kuri_id uuid)
returns table(id uuid, registered_name text, display_name text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.id,p.registered_name,p.display_name
  from public.people p
  join public.kuris k on k.organization_id = p.organization_id
  where k.id = target_kuri_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id = k.organization_id
        and ou.user_id = auth.uid()
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  order by coalesce(nullif(p.display_name,''),p.registered_name),p.registered_name;
$function$;

-- Harden membership creation against cross-tenant assignment, closed Kuris and capacity overflow.
create or replace function public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  target_membership_number text
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
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
  values(target_kuri_id,target_person_id,nullif(btrim(target_membership_number),''),'ACTIVE')
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
$function$;

revoke execute on function public.create_person_for_org_admin(uuid,text,text,text,text,text,text) from public,anon;
grant execute on function public.create_person_for_org_admin(uuid,text,text,text,text,text,text) to authenticated;

revoke execute on function public.create_person_for_admin(text,text,text,text,text,text) from public,anon;
grant execute on function public.create_person_for_admin(text,text,text,text,text,text) to authenticated;

revoke execute on function public.list_people_for_admin() from public,anon;
grant execute on function public.list_people_for_admin() to authenticated;

revoke execute on function public.get_person_for_admin(uuid) from public,anon;
grant execute on function public.get_person_for_admin(uuid) to authenticated;

revoke execute on function public.list_people_available_for_membership(uuid) from public,anon;
grant execute on function public.list_people_available_for_membership(uuid) to authenticated;

revoke execute on function public.create_membership_for_admin(uuid,uuid,text) from public,anon;
grant execute on function public.create_membership_for_admin(uuid,uuid,text) to authenticated;

-- The direct people table remains policy-protected; anonymous access is never allowed.
