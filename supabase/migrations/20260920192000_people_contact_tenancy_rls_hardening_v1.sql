-- Scope person contact RLS to the owning organization.
-- The previous policy used current_user_is_admin(), which did not constrain
-- an administrator to the person's organization.

drop policy if exists person_emails_admin_all on public.person_emails;
create policy person_emails_admin_all
on public.person_emails
for all
to authenticated
using (
  exists (
    select 1
    from public.people p
    where p.id = person_emails.person_id
      and has_org_role(
        p.organization_id,
        array['MAIN_ADMIN','ADMIN']::public.app_role[]
      )
  )
)
with check (
  exists (
    select 1
    from public.people p
    where p.id = person_emails.person_id
      and has_org_role(
        p.organization_id,
        array['MAIN_ADMIN','ADMIN']::public.app_role[]
      )
  )
);

drop policy if exists person_phones_admin_all on public.person_phones;
create policy person_phones_admin_all
on public.person_phones
for all
to authenticated
using (
  exists (
    select 1
    from public.people p
    where p.id = person_phones.person_id
      and has_org_role(
        p.organization_id,
        array['MAIN_ADMIN','ADMIN']::public.app_role[]
      )
  )
)
with check (
  exists (
    select 1
    from public.people p
    where p.id = person_phones.person_id
      and has_org_role(
        p.organization_id,
        array['MAIN_ADMIN','ADMIN']::public.app_role[]
      )
  )
);