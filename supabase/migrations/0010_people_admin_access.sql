begin;

-- Admins need table-level privileges in addition to RLS policies for people management.
grant select, insert, update, delete on table public.people to authenticated;
grant select, insert, update, delete on table public.person_phones to authenticated;
grant select, insert, update, delete on table public.person_emails to authenticated;

-- Allow workspace admins to manage people belonging to their workspace.
create policy people_admin_select
on public.people
for select
using (
  exists (
    select 1
    from public.organization_users ou
    join public.memberships m on m.person_id = people.id
    join public.kuris k on k.id = m.kuri_id
    where ou.organization_id = k.organization_id
      and ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
  or exists (
    select 1
    from public.users u
    where u.id = auth.uid()
      and u.person_id = people.id
  )
);

create policy people_admin_insert
on public.people
for insert
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

create policy people_admin_update
on public.people
for update
using (
  exists (
    select 1
    from public.organization_users ou
    join public.memberships m on m.person_id = people.id
    join public.kuris k on k.id = m.kuri_id
    where ou.organization_id = k.organization_id
      and ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
)
with check (true);

create policy people_admin_delete
on public.people
for delete
using (
  exists (
    select 1
    from public.organization_users ou
    join public.memberships m on m.person_id = people.id
    join public.kuris k on k.id = m.kuri_id
    where ou.organization_id = k.organization_id
      and ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

commit;
