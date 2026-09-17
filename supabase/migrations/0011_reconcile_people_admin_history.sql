begin;

-- Reconcile migrations 0011-0014 that were previously applied to the
-- database but intentionally removed from the source tree. This migration is
-- itself the only new file and restores the final People admin RPC/policies.

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

revoke all on function public.current_user_is_admin() from public;
grant execute on function public.current_user_is_admin() to authenticated;

create or replace function public.list_people_for_admin()
returns table (
  id uuid,
  registered_name text,
  display_name text,
  address text,
  created_at timestamptz
)
language sql
security definer
set search_path = public
stable
as $$
  select p.id, p.registered_name, p.display_name, p.address, p.created_at
  from public.people p
  where public.current_user_is_admin()
  order by p.created_at desc;
$$;

revoke all on function public.list_people_for_admin() from public;
grant execute on function public.list_people_for_admin() to authenticated;

-- Keep the global people registry accessible only through the admin path.
drop policy if exists people_select on public.people;
drop policy if exists people_admin_select on public.people;
drop policy if exists people_admin_insert on public.people;
drop policy if exists people_admin_update on public.people;
drop policy if exists people_admin_delete on public.people;

grant select, insert, update, delete on table public.people to authenticated;

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

drop policy if exists person_phones_admin_all on public.person_phones;
drop policy if exists person_emails_admin_all on public.person_emails;

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
