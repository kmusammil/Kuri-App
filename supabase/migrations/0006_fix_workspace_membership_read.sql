begin;

-- Replace the recursive/ambiguous organization membership read with a
-- security-definer helper that checks the signed-in user's own membership.
create or replace function public.current_user_membership()
returns table (organization_id uuid, role public.app_role)
language sql
security definer
set search_path = public
stable
as $$
  select ou.organization_id, ou.role
  from public.organization_users ou
  where ou.user_id = auth.uid()
  order by ou.created_at asc
  limit 1;
$$;

revoke all on function public.current_user_membership() from public;
grant execute on function public.current_user_membership() to authenticated;

drop policy if exists organization_users_self_select on public.organization_users;
create policy organization_users_self_select_v2
on public.organization_users
for select
using (user_id = auth.uid());

commit;
