begin;

-- Resolve the current user's workspace role without depending on a
-- client-side organization_users RLS query.
create or replace function public.get_my_workspace_role()
returns public.app_role
language sql
security definer
set search_path = public
stable
as $$
  select ou.role
  from public.organization_users ou
  where ou.user_id = auth.uid()
  order by ou.created_at asc
  limit 1;
$$;

revoke all on function public.get_my_workspace_role() from public;
grant execute on function public.get_my_workspace_role() to authenticated;

commit;
