begin;

-- Finalize People RLS without querying protected tables from the policy.
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
      and ou.role in ('MAIN_ADMIN','ADMIN')
  );
$$;

revoke all on function public.current_user_is_admin() from public;
grant execute on function public.current_user_is_admin() to authenticated;

drop policy if exists people_admin_select on public.people;
drop policy if exists people_admin_insert on public.people;
drop policy if exists people_admin_update on public.people;
drop policy if exists people_admin_delete on public.people;

drop policy if exists person_phones_admin_all on public.person_phones;
drop policy if exists person_emails_admin_all on public.person_emails;

create policy people_admin_select
on public.people
for select
using (public.current_user_is_admin());

create policy people_admin_insert
on public.people
for insert
with check (public.current_user_is_admin());

create policy people_admin_update
on public.people
for update
using (public.current_user_is_admin())
with check (public.current_user_is_admin());

create policy people_admin_delete
on public.people
for delete
using (public.current_user_is_admin());

create policy person_phones_admin_all
on public.person_phones
for all
using (public.current_user_is_admin())
with check (public.current_user_is_admin());

create policy person_emails_admin_all
on public.person_emails
for all
using (public.current_user_is_admin())
with check (public.current_user_is_admin());

commit;
