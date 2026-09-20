begin;

drop policy if exists users_self_select on public.users;
create policy users_self_select on public.users
for select to public
using (id = (select auth.uid()));

drop policy if exists organization_users_self_select_v2 on public.organization_users;
create policy organization_users_self_select_v2 on public.organization_users
for select to public
using (user_id = (select auth.uid()));

drop policy if exists organizations_self_select on public.organizations;
create policy organizations_self_select on public.organizations
for select to public
using (
  exists (
    select 1 from public.organization_users ou
    where ou.organization_id=organizations.id
      and ou.user_id=(select auth.uid())
  )
);

drop policy if exists payments_select on public.payments;
create policy payments_select on public.payments
for select to public
using (
  exists (
    select 1 from public.users u
    where u.id=(select auth.uid())
      and u.person_id=payments.person_id
  )
  or
  (select public.has_org_role(
    (
      select k.organization_id
      from public.memberships m
      join public.kuris k on k.id=m.kuri_id
      join public.installments i on i.membership_id=m.id
      join public.payment_allocations pa on pa.installment_id=i.id
      where pa.payment_id=payments.id
      limit 1
    ),
    array['MAIN_ADMIN'::public.app_role,'ADMIN'::public.app_role]
  ))
);

commit;