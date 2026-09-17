begin;

-- Allow an authenticated user to see their own organization memberships.
-- This is needed by server-side application code to determine the active workspace
-- and role before performing organization-scoped mutations.
create policy organization_users_self_select on public.organization_users
for select
using (user_id = auth.uid());

commit;
