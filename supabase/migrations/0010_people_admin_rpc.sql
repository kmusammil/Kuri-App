begin;

-- Admin-only RPC for the global people registry. The SECURITY DEFINER function
-- performs the authorization check internally and returns people directly,
-- avoiding client-side RLS traversal through application tables.
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

-- Admin RPCs perform their own authorization, so direct authenticated reads of
-- the global people registry are not needed.
drop policy if exists people_select on public.people;

grant select on table public.people to authenticated;

commit;
