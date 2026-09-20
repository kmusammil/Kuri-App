begin;

create or replace function public.list_installments_for_payment_admin(target_kuri_id uuid)
returns table (id uuid,membership_id uuid,membership_number text,registered_name text,display_name text,cycle_id uuid,cycle_number integer,amount_due bigint,amount_paid bigint,balance bigint,status public.installment_status,due_date date)
language sql security definer set search_path=public stable
as $$
  select i.id,i.membership_id,m.membership_number,p.registered_name,p.display_name,i.cycle_id,c.cycle_number,i.amount_due,i.amount_paid,greatest(i.amount_due-i.amount_paid,0),i.status,i.due_date
  from public.installments i join public.memberships m on m.id=i.membership_id join public.people p on p.id=m.person_id join public.cycles c on c.id=i.cycle_id join public.kuris k on k.id=c.kuri_id
  where k.id=target_kuri_id and exists (select 1 from public.organization_users ou where ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]))
  order by c.cycle_number,m.membership_number;
$$;

create or replace function public.create_payment_for_admin(target_person_id uuid,payment_amount bigint,payment_date timestamptz,payment_method public.payment_method,payment_reference text default null,payment_notes text default null)
returns uuid language plpgsql security definer set search_path=public
as $$
declare payment_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if payment_amount<=0 then raise exception 'Payment amount must be greater than zero.'; end if;
  if not exists (select 1 from public.memberships m join public.kuris k on k.id=m.kuri_id join public.organization_users ou on ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]) where m.person_id=target_person_id) then raise exception 'You do not have permission to record payments for this person.'; end if;
  insert into public.payments(person_id,amount,payment_date,method,reference_number,status,notes)
  values(target_person_id,payment_amount,payment_date,payment_method,nullif(btrim(payment_reference),''),'APPROVED',nullif(btrim(payment_notes),''))
  returning id into payment_id;
  return payment_id;
end;
$$;

create or replace function public.get_payment_for_admin(target_payment_id uuid)
returns table (id uuid,person_id uuid,registered_name text,display_name text,amount bigint,payment_date timestamptz,method public.payment_method,reference_number text,status public.payment_status,notes text,submitted_at timestamptz,verified_at timestamptz)
language sql security definer set search_path=public stable
as $$
  select p.id,p.person_id,pe.registered_name,pe.display_name,p.amount,p.payment_date,p.method,p.reference_number,p.status,p.notes,p.submitted_at,p.verified_at
  from public.payments p join public.people pe on pe.id=p.person_id
  where p.id=target_payment_id and exists (select 1 from public.memberships m join public.kuris k on k.id=m.kuri_id join public.organization_users ou on ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]) where m.person_id=p.person_id);
$$;

create or replace function public.list_payments_for_admin()
returns table (id uuid,person_id uuid,registered_name text,display_name text,amount bigint,payment_date timestamptz,method public.payment_method,reference_number text,status public.payment_status)
language sql security definer set search_path=public stable
as $$
  select p.id,p.person_id,pe.registered_name,pe.display_name,p.amount,p.payment_date,p.method,p.reference_number,p.status
  from public.payments p join public.people pe on pe.id=p.person_id
  where exists (select 1 from public.memberships m join public.kuris k on k.id=m.kuri_id join public.organization_users ou on ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]) where m.person_id=p.person_id)
  order by p.payment_date desc,p.created_at desc;
$$;

create or replace function public.list_payment_allocations_for_admin(target_payment_id uuid)
returns table (id uuid,installment_id uuid,kuri_id uuid,kuri_name text,cycle_number integer,membership_number text,amount bigint)
language sql security definer set search_path=public stable
as $$
  select pa.id,i.id,k.id,k.name,c.cycle_number,m.membership_number,pa.amount
  from public.payment_allocations pa join public.payments p on p.id=pa.payment_id join public.installments i on i.id=pa.installment_id join public.memberships m on m.id=i.membership_id join public.cycles c on c.id=i.cycle_id join public.kuris k on k.id=c.kuri_id
  where pa.payment_id=target_payment_id and exists (select 1 from public.organization_users ou where ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]))
  order by k.name,c.cycle_number,m.membership_number;
$$;

create or replace function public.allocate_payment_for_admin(target_payment_id uuid,target_installment_id uuid,allocation_amount bigint)
returns bigint language plpgsql security definer set search_path=public
as $$
declare payment_person_id uuid; payment_total bigint; payment_status public.payment_status; installment_membership_id uuid; installment_person_id uuid; installment_amount_due bigint; installment_amount_paid bigint; target_org_id uuid; already_allocated bigint; next_paid bigint;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if allocation_amount<=0 then raise exception 'Allocation amount must be greater than zero.'; end if;
  select p.person_id,p.amount,p.status into payment_person_id,payment_total,payment_status from public.payments p where p.id=target_payment_id;
  if not found then raise exception 'Payment not found.'; end if;
  select i.membership_id,i.amount_due,i.amount_paid,m.person_id,k.organization_id into installment_membership_id,installment_amount_due,installment_amount_paid,installment_person_id,target_org_id
  from public.installments i join public.memberships m on m.id=i.membership_id join public.kuris k on k.id=m.kuri_id where i.id=target_installment_id;
  if not found then raise exception 'Installment not found.'; end if;
  if payment_person_id<>installment_person_id then raise exception 'Payment person does not match installment person.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=target_org_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to allocate this payment.'; end if;
  if payment_status<>'APPROVED' then raise exception 'Only approved payments can be allocated.'; end if;
  select coalesce(sum(pa.amount),0) into already_allocated from public.payment_allocations pa where pa.payment_id=target_payment_id;
  if already_allocated+allocation_amount>payment_total then raise exception 'Allocation exceeds payment amount.'; end if;
  if allocation_amount>greatest(installment_amount_due-installment_amount_paid,0) then raise exception 'Allocation exceeds installment balance.'; end if;
  insert into public.payment_allocations(payment_id,installment_id,amount,allocated_by) values(target_payment_id,target_installment_id,allocation_amount,(select id from public.users where id=auth.uid()))
  on conflict(payment_id,installment_id) do update set amount=public.payment_allocations.amount+excluded.amount,allocated_at=now(),allocated_by=excluded.allocated_by;
  next_paid:=installment_amount_paid+allocation_amount;
  update public.installments set amount_paid=next_paid,status=case when next_paid>=amount_due then 'PAID'::public.installment_status when next_paid>0 then 'PARTIAL'::public.installment_status else 'UNPAID'::public.installment_status end,updated_at=now() where id=target_installment_id;
  return next_paid;
end;
$$;

revoke all on function public.list_installments_for_payment_admin(uuid) from public;
revoke all on function public.create_payment_for_admin(uuid,bigint,timestamptz,public.payment_method,text,text) from public;
revoke all on function public.get_payment_for_admin(uuid) from public;
revoke all on function public.list_payments_for_admin() from public;
revoke all on function public.list_payment_allocations_for_admin(uuid) from public;
revoke all on function public.allocate_payment_for_admin(uuid,uuid,bigint) from public;
grant execute on function public.list_installments_for_payment_admin(uuid) to authenticated;
grant execute on function public.create_payment_for_admin(uuid,bigint,timestamptz,public.payment_method,text,text) to authenticated;
grant execute on function public.get_payment_for_admin(uuid) to authenticated;
grant execute on function public.list_payments_for_admin() to authenticated;
grant execute on function public.list_payment_allocations_for_admin(uuid) to authenticated;
grant execute on function public.allocate_payment_for_admin(uuid,uuid,bigint) to authenticated;

commit;