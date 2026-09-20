-- Deep backend audit hardening: eliminate redundant permissive RLS policies
-- and prevent future public-schema objects from being auto-exposed.

begin;

drop policy if exists kuris_insert_admin_v2 on public.kuris;
drop policy if exists kuris_update_admin_v2 on public.kuris;
drop policy if exists organization_users_self_select_v2 on public.organization_users;
drop policy if exists organizations_self_select on public.organizations;

-- New public-schema functions/tables created by postgres should not become
-- reachable through the Data API until a migration explicitly grants access.
alter default privileges for role postgres in schema public
  revoke execute on functions from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke usage, select, update on sequences from anon, authenticated;

commit;