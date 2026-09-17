begin;

-- The earlier admin helper still executed a direct query against
-- organization_users. PostgreSQL evaluates function table access privileges
-- separately from the caller's RLS, so use the existing security-definer
-- workspace membership helper instead.
create or replace function public.current_user_is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  );
$$;

-- A security-definer function owned by the migration owner can read the
-- membership table without requiring authenticated table privileges.
revoke all on function public.current_user_is_admin() from public;
grant execute on function public.current_user_is_admin() to authenticated;

drop policy if exists people_admin_select on public.people;
create policy people_admin_select
on public.people
for select
using (public.current_user_is_admin());

drop policy if exists people_admin_insert on public.people;
create policy people_admin_insert
on public.people
for insert
with check (public.current_user_is_admin());

drop policy if exists people_admin_update on public.people;
create policy people_admin_update
on public.people
for update
using (public.current_user_is_admin())
with check (public.current_user_is_admin());

drop policy if exists people_admin_delete on public.people;
create policy people_admin_delete
on public.people
for delete
using (public.current_user_is_admin());

drop policy if exists person_phones_admin_all on public.person_phones;
create policy person_phones_admin_all
on public.person_phones
for all
using (public.current_user_is_admin())
with check (public.current_user_is_admin());

drop policy if exists person_emails_admin_all on public.person_emails;
create policy person_emails_admin_all
on public.person_emails
for all
using (public.current_user_is_admin())
with check (public.current_user_is_admin());

commit;
