begin;

-- Refresh the People admin RPC in the remote database. Migration 0010 may
-- already be recorded as applied, so this migration explicitly recreates the
-- function and its PostgREST execute grant.
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
  where exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
  order by p.created_at desc;
$$;

revoke all on function public.list_people_for_admin() from public;
grant execute on function public.list_people_for_admin() to authenticated;

grant usage on schema public to authenticated;

commit;
