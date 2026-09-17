begin;

-- Admins can create and manage Kuris within their workspace.
create policy kuris_insert_admin_v2 on kuris
for insert
with check (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::app_role[])
);

create policy kuris_update_admin_v2 on kuris
for update
using (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::app_role[])
)
with check (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::app_role[])
);

create policy kuris_delete_admin_v2 on kuris
for delete
using (
  public.has_org_role(organization_id, array['MAIN_ADMIN','ADMIN']::app_role[])
);

commit;
