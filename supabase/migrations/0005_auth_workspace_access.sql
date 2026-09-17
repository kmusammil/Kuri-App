-- Make authenticated workspace membership readable by the signed-in user.
create policy organization_users_self_select on public.organization_users
for select
using (user_id = auth.uid());

-- Allow an authenticated user to read organizations they belong to.
create policy organizations_self_select on public.organizations
for select
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = organizations.id
      and ou.user_id = auth.uid()
  )
);
