begin;

-- Authenticated users need table privileges in addition to RLS policies.
grant select, insert, update, delete on table public.people to authenticated;
grant select, insert, update, delete on table public.person_phones to authenticated;
grant select, insert, update, delete on table public.person_emails to authenticated;
grant select on table public.organization_users to authenticated;

-- Workspace admins may manage people records.
create policy people_admin_select on public.people
for select
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

create policy people_admin_insert on public.people
for insert
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

create policy people_admin_update on public.people
for update
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
)
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

create policy people_admin_delete on public.people
for delete
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

-- Contact details are owned by their person record; admins can manage them.
create policy person_phones_admin_all on public.person_phones
for all
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
)
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

create policy person_emails_admin_all on public.person_emails
for all
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
)
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and public.has_org_role(ou.organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

commit;
