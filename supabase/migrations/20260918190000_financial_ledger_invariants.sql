begin;

create or replace function public.reconcile_installment_from_allocations(target_installment_id uuid)
returns bigint
language plpgsql security definer set search_path=public
as $$
declare
  target_amount_due bigint;
  allocated_total bigint;
  target_org_id uuid;
  target_amount_paid bigint;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select i.amount_due,k.organization_id
    into target_amount_due,target_org_id
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.kuris k on k.id=m.kuri_id
  where i.id=target_installment_id;

  if target_org_id is null then raise exception 'Installment not found.'; end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to reconcile this installment.';
  end if;

  select coalesce(sum(pa.amount),0)
    into allocated_total
  from public.payment_allocations pa
  where pa.installment_id=target_installment_id;

  target_amount_paid := least(greatest(allocated_total,0),target_amount_due);

  update public.installments
  set amount_paid=target_amount_paid,
      status=case
        when target_amount_paid>=amount_due then 'PAID'::public.installment_status
        when target_amount_paid>0 then 'PARTIAL'::public.installment_status
        else 'UNPAID'::public.installment_status
      end,
      updated_at=now()
  where id=target_installment_id;

  return target_amount_paid;
end;
$$;

create or replace function public.audit_financial_ledger_for_admin()
returns table(
  approved_payment_total bigint,
  allocation_total bigint,
  installment_paid_total bigint,
  unallocated_approved_payment bigint,
  installment_allocation_gap bigint
)
language plpgsql security definer set search_path=public
as $$
declare
  org_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select ou.organization_id
    into org_id
  from public.organization_users ou
  where ou.user_id=auth.uid()
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  limit 1;

  if org_id is null then raise exception 'You do not have permission to audit the financial ledger.'; end if;

  return query
  with approved as (
    select coalesce(sum(p.amount),0) total
    from public.payments p
    where p.status='APPROVED'
      and exists (
        select 1
        from public.memberships m
        join public.kuris k on k.id=m.kuri_id
        where m.person_id=p.person_id
          and k.organization_id=org_id
      )
  ),
  allocated as (
    select coalesce(sum(pa.amount),0) total
    from public.payment_allocations pa
    join public.installments i on i.id=pa.installment_id
    join public.memberships m on m.id=i.membership_id
    join public.kuris k on k.id=m.kuri_id
    where k.organization_id=org_id
  ),
  installment_paid as (
    select coalesce(sum(i.amount_paid),0) total
    from public.installments i
    join public.memberships m on m.id=i.membership_id
    join public.kuris k on k.id=m.kuri_id
    where k.organization_id=org_id
  )
  select approved.total,
         allocated.total,
         installment_paid.total,
         greatest(approved.total-allocated.total,0),
         greatest(installment_paid.total-allocated.total,0)
  from approved,allocated,installment_paid;
end;
$$;

revoke all on function public.reconcile_installment_from_allocations(uuid) from public;
revoke all on function public.audit_financial_ledger_for_admin() from public;
grant execute on function public.reconcile_installment_from_allocations(uuid) to authenticated;
grant execute on function public.audit_financial_ledger_for_admin() to authenticated;

commit;
