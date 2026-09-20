begin;

-- Replace the missing workspace lookup with a single trusted helper.
create or replace function public.get_my_workspace_id()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select ou.organization_id
  from public.organization_users ou
  where ou.user_id = auth.uid()
  order by ou.created_at asc
  limit 1;
$$;

revoke all on function public.get_my_workspace_id() from public;
grant execute on function public.get_my_workspace_id() to authenticated;

commit;
