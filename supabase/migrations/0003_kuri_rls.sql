-- Allow Kuri administrators to create and manage Kuri schemes in their workspace.

create policy kuris_insert on public.kuris
for insert
with check (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
);

create policy kuris_update on public.kuris
for update
using (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
)
with check (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
);

create policy kuris_delete on public.kuris
for delete
using (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::public.app_role[])
);
