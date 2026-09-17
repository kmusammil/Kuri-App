-- Allow authenticated users to see their own workspace memberships.

create policy organization_users_self_select on public.organization_users
for select
using (user_id = auth.uid());
