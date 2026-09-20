begin;

-- Financial ledger hardening.
-- Scope payments to an organization, close cross-tenant allocation paths,
-- serialize payment/installment allocation, and enforce payout invariants.

alter table public.payments add column if not exists organization_id uuid;

do $$
declare unresolved_count integer; cross_org_count integer;
begin
  select count(*) into cross_org_count
  from (
    select pa.payment_id
    from public.payment_allocations pa
    join public.installments i on i.id=pa.installment_id
    join public.memberships m on m.id=i.membership_id
    join public.kuris k on k.id=m.kuri_id
    group by pa.payment_id
    having count(distinct k.organization_id)>1
  ) x;

  if cross_org_count>0 then
    raise exception 'Cannot backfill payments.organization_id: % payment(s) have allocations across multiple organizations.',cross_org_count;
  end if;

  update public.payments p
  set organization_id=x.organization_id
  from (
    select pa.payment_id,(array_agg(k.organization_id order by k.organization_id))[1] organization_id
    from public.payment_allocations pa
    join public.installments i on i.id=pa.installment_id
    join public.memberships m on m.id=i.membership_id
    join public.kuris k on k.id=m.kuri_id
    group by pa.payment_id
  ) x
  where p.id=x.payment_id and p.organization_id is null;

  update public.payments p
  set organization_id=x.organization_id
  from (
    select p2.id,(array_agg(k.organization_id order by k.organization_id))[1] organization_id
    from public.payments p2
    join public.memberships m on m.person_id=p2.person_id
    join public.kuris k on k.id=m.kuri_id
    group by p2.id
    having count(distinct k.organization_id)=1
  ) x
  where p.id=x.id and p.organization_id is null;

  select count(*) into unresolved_count
  from public.payments where organization_id is null;

  if unresolved_count>0 then
    raise exception 'Cannot make payments.organization_id NOT NULL: % payment(s) could not be assigned to an organization.',unresolved_count;
  end if;
end $$;

alter table public.payments alter column organization_id set not null;
alter table public.payments
  add constraint payments_organization_id_fkey
  foreign key (organization_id) references public.organizations(id);

create index if not exists payments_organization_id_idx
  on public.payments(organization_id);

alter table public.muppu_records
  add constraint muppu_records_kuri_cycle_person_key
  unique(kuri_id,cycle_id,person_id);

alter table public.payouts
  add constraint payouts_monthly_winner_id_key
  unique(monthly_winner_id);

alter table public.payouts
  add constraint payouts_net_amount_invariant
  check(net_amount=greatest(gross_amount-muppu_amount-other_deductions,0));

alter table public.payouts
  add constraint payouts_paid_details_invariant
  check(status<>'PAID' or (payment_date is not null and method is not null));

create or replace function public.create_payment_for_admin(
  target_person_id uuid,payment_amount bigint,payment_date timestamptz,
  payment_method public.payment_method,payment_reference text default null,
  payment_notes text default null
)
returns uuid language plpgsql security definer set search_path=public
as $$
declare payment_id uuid; target_org_id uuid; org_count integer;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if payment_amount<=0 then raise exception 'Payment amount must be greater than zero.'; end if;

  select count(distinct k.organization_id),
         (array_agg(k.organization_id order by k.organization_id))[1]
    into org_count,target_org_id
  from public.memberships m
  join public.kuris k on k.id=m.kuri_id
  join public.organization_users ou
    on ou.organization_id=k.organization_id
   and ou.user_id=auth.uid()
   and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  where m.person_id=target_person_id;

  if org_count=0 then
    raise exception 'You do not have permission to record payments for this person.';
  end if;
  if org_count>1 then
    raise exception 'This person belongs to multiple organizations. Payment creation must be organization-scoped.';
  end if;

  insert into public.payments(
    organization_id,person_id,amount,payment_date,method,reference_number,status,notes
  ) values (
    target_org_id,target_person_id,payment_amount,payment_date,payment_method,
    nullif(btrim(payment_reference),''),'APPROVED',nullif(btrim(payment_notes),'')
  )
  returning id into payment_id;

  return payment_id;
end $$;

create or replace function public.list_payments_for_admin()
returns table(
  id uuid,person_id uuid,registered_name text,display_name text,amount bigint,
  payment_date timestamptz,method public.payment_method,reference_number text,
  status public.payment_status
)
language sql security definer set search_path=public stable
as $$
  select p.id,p.person_id,pe.registered_name,pe.display_name,p.amount,
         p.payment_date,p.method,p.reference_number,p.status
  from public.payments p
  join public.people pe on pe.id=p.person_id
  where exists (
    select 1 from public.organization_users ou
    where ou.organization_id=p.organization_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
  order by p.payment_date desc,p.created_at desc;
$$;

create or replace function public.get_payment_for_admin(target_payment_id uuid)
returns table(
  id uuid,person_id uuid,registered_name text,display_name text,amount bigint,
  payment_date timestamptz,method public.payment_method,reference_number text,
  status public.payment_status,notes text,submitted_at timestamptz,
  verified_at timestamptz
)
language sql security definer set search_path=public stable
as $$
  select p.id,p.person_id,pe.registered_name,pe.display_name,p.amount,
         p.payment_date,p.method,p.reference_number,p.status,p.notes,
         p.submitted_at,p.verified_at
  from public.payments p
  join public.people pe on pe.id=p.person_id
  where p.id=target_payment_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=p.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$$;

create or replace function public.list_payment_allocations_for_admin(target_payment_id uuid)
returns table(
  id uuid,installment_id uuid,kuri_id uuid,kuri_name text,cycle_number integer,
  membership_number text,amount bigint
)
language sql security definer set search_path=public stable
as $$
  select pa.id,i.id,k.id,k.name,c.cycle_number,m.membership_number,pa.amount
  from public.payment_allocations pa
  join public.payments p on p.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  join public.memberships m on m.id=i.membership_id
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where pa.payment_id=target_payment_id
    and p.organization_id=k.organization_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=p.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  order by k.name,c.cycle_number,m.membership_number;
$$;

create or replace function public.allocate_payment_for_admin(
  target_payment_id uuid,target_installment_id uuid,allocation_amount bigint
)
returns bigint language plpgsql security definer set search_path=public
as $$
declare
  payment_person_id uuid; payment_total bigint; payment_status public.payment_status;
  payment_org_id uuid; installment_person_id uuid; installment_amount_due bigint;
  target_org_id uuid; already_allocated bigint; installment_allocated bigint;
  next_paid bigint;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if allocation_amount<=0 then raise exception 'Allocation amount must be greater than zero.'; end if;

  select p.person_id,p.amount,p.status,p.organization_id
    into payment_person_id,payment_total,payment_status,payment_org_id
  from public.payments p
  where p.id=target_payment_id
  for update;

  if not found then raise exception 'Payment not found.'; end if;

  select i.amount_due,m.person_id,k.organization_id
    into installment_amount_due,installment_person_id,target_org_id
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.kuris k on k.id=m.kuri_id
  where i.id=target_installment_id
  for update;

  if not found then raise exception 'Installment not found.'; end if;
  if payment_person_id<>installment_person_id then
    raise exception 'Payment person does not match installment person.';
  end if;
  if payment_org_id<>target_org_id then
    raise exception 'Payment and installment belong to different organizations.';
  end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to allocate this payment.';
  end if;

  if payment_status<>'APPROVED' then
    raise exception 'Only approved payments can be allocated.';
  end if;

  select coalesce(sum(pa.amount),0)
    into already_allocated
  from public.payment_allocations pa
  where pa.payment_id=target_payment_id;

  select coalesce(sum(pa.amount),0)
    into installment_allocated
  from public.payment_allocations pa
  where pa.installment_id=target_installment_id;

  if already_allocated+allocation_amount>payment_total then
    raise exception 'Allocation exceeds payment amount.';
  end if;
  if installment_allocated+allocation_amount>installment_amount_due then
    raise exception 'Allocation exceeds installment balance.';
  end if;

  insert into public.payment_allocations(
    payment_id,installment_id,amount,allocated_by
  ) values (
    target_payment_id,target_installment_id,allocation_amount,
    (select id from public.users where id=auth.uid())
  )
  on conflict(payment_id,installment_id)
  do update set
    amount=public.payment_allocations.amount+excluded.amount,
    allocated_at=now(),
    allocated_by=excluded.allocated_by;

  select coalesce(sum(pa.amount),0)
    into installment_allocated
  from public.payment_allocations pa
  where pa.installment_id=target_installment_id;

  next_paid:=least(installment_allocated,installment_amount_due);

  update public.installments
  set amount_paid=next_paid,
      status=case
        when next_paid>=amount_due then 'PAID'::public.installment_status
        when next_paid>0 then 'PARTIAL'::public.installment_status
        else 'UNPAID'::public.installment_status
      end,
      updated_at=now()
  where id=target_installment_id;

  return next_paid;
end $$;

create or replace function public.prepare_payout_for_admin(target_winner_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare payout_id uuid; winner_person_id uuid; winner_cycle_id uuid;
gross_amount bigint; configured_muppu_amount bigint; deducted_muppu_amount bigint;
payout_muppu_amount bigint; cycle_status_value public.cycle_status;
begin
  select mw.person_id,mw.cycle_id,k.gross_prize_amount,k.muppu_amount,c.status
    into winner_person_id,winner_cycle_id,gross_amount,configured_muppu_amount,cycle_status_value
  from public.monthly_winners mw
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where mw.id=target_winner_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );

  if winner_person_id is null then raise exception 'Monthly winner not found.'; end if;
  if cycle_status_value<>'COMPLETED' then raise exception 'Cycle must be COMPLETED before preparing a payout.'; end if;
  if gross_amount<=0 then raise exception 'Gross prize amount must be greater than zero.'; end if;

  select coalesce(sum(mr.amount),0) into deducted_muppu_amount
  from public.muppu_records mr
  where mr.person_id=winner_person_id
    and mr.cycle_id=winner_cycle_id
    and mr.status='DEDUCTED';

  payout_muppu_amount:=greatest(coalesce(configured_muppu_amount,0),deducted_muppu_amount);

  insert into public.payouts(
    monthly_winner_id,gross_amount,muppu_amount,other_deductions,net_amount,status
  ) values (
    target_winner_id,gross_amount,payout_muppu_amount,0,
    greatest(gross_amount-payout_muppu_amount,0),'PENDING'
  )
  on conflict(monthly_winner_id)
  do update set
    gross_amount=excluded.gross_amount,
    muppu_amount=excluded.muppu_amount,
    net_amount=greatest(
      excluded.gross_amount-excluded.muppu_amount-public.payouts.other_deductions,0
    )
  where public.payouts.status='PENDING'
  returning id into payout_id;

  if payout_id is null then
    select po.id into payout_id
    from public.payouts po
    where po.monthly_winner_id=target_winner_id;
  end if;

  return payout_id;
end $$;

create or replace function public.mark_payout_paid_for_admin(
  target_winner_id uuid,payout_payment_date timestamptz,
  payout_method public.payment_method,payout_reference text default null,
  payout_notes text default null,payout_other_deductions bigint default 0
)
returns void language plpgsql security definer set search_path=public
as $$
declare payout_row public.payouts%rowtype; target_org_id uuid; computed_net_amount bigint;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if payout_other_deductions<0 then raise exception 'Other deductions cannot be negative.'; end if;

  perform public.prepare_payout_for_admin(target_winner_id);

  select po.* into payout_row
  from public.payouts po
  join public.monthly_winners mw on mw.id=po.monthly_winner_id
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where po.monthly_winner_id=target_winner_id
  for update;

  if not found then raise exception 'Payout not found.'; end if;

  select k.organization_id into target_org_id
  from public.monthly_winners mw
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where mw.id=target_winner_id;

  if target_org_id is null then raise exception 'Monthly winner not found.'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to process this payout.';
  end if;

  if payout_row.status<>'PENDING' then
    raise exception 'Only a PENDING payout can be marked PAID.';
  end if;

  perform public.transition_payout_status_for_admin(payout_row.id,'PROCESSING');

  computed_net_amount:=greatest(
    payout_row.gross_amount-payout_row.muppu_amount-payout_other_deductions,0
  );

  update public.payouts
  set other_deductions=payout_other_deductions,
      net_amount=computed_net_amount,
      payment_date=coalesce(payout_payment_date,now()),
      method=payout_method,
      reference_number=nullif(btrim(payout_reference),''),
      processed_by=(select id from public.users where id=auth.uid()),
      notes=nullif(btrim(payout_notes),'')
  where id=payout_row.id;

  perform public.transition_payout_status_for_admin(payout_row.id,'PAID');
end $$;

create or replace function public.audit_financial_ledger_for_admin()
returns table(
  approved_payment_total bigint,allocation_total bigint,installment_paid_total bigint,
  unallocated_approved_payment bigint,installment_allocation_gap bigint
)
language plpgsql security definer set search_path=public
as $$
declare org_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select ou.organization_id into org_id
  from public.organization_users ou
  where ou.user_id=auth.uid()
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by case when ou.role='MAIN_ADMIN' then 0 else 1 end,ou.organization_id
  limit 1;

  if org_id is null then raise exception 'You do not have permission to audit the financial ledger.'; end if;

  return query
  with approved as (
    select coalesce(sum(p.amount),0) total
    from public.payments p
    where p.status='APPROVED' and p.organization_id=org_id
  ),
  allocated as (
    select coalesce(sum(pa.amount),0) total
    from public.payment_allocations pa
    join public.payments p on p.id=pa.payment_id
    where p.organization_id=org_id
  ),
  installment_paid as (
    select coalesce(sum(i.amount_paid),0) total
    from public.installments i
    join public.memberships m on m.id=i.membership_id
    join public.kuris k on k.id=m.kuri_id
    where k.organization_id=org_id
  )
  select approved.total,allocated.total,installment_paid.total,
         greatest(approved.total-allocated.total,0),
         greatest(installment_paid.total-allocated.total,0)
  from approved,allocated,installment_paid;
end $$;

create or replace function public.refresh_membership_exit_financials_for_admin(target_exit_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare target_org_id uuid; target_membership_id uuid; contributed_amount bigint:=0;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id,me.membership_id
    into target_org_id,target_membership_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to refresh this exit.'; end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id
    and pay.status='APPROVED'
    and pay.organization_id=target_org_id;

  update public.membership_exits me
  set amount_contributed=contributed_amount,
      refund_amount=case
        when coalesce(me.refund_amount,0)=0 then contributed_amount
        else least(me.refund_amount,contributed_amount)
      end
  where me.id=target_exit_id;
end $$;

revoke all on function public.create_payment_for_admin(uuid,bigint,timestamptz,public.payment_method,text,text) from public;
revoke all on function public.list_payments_for_admin() from public;
revoke all on function public.get_payment_for_admin(uuid) from public;
revoke all on function public.list_payment_allocations_for_admin(uuid) from public;
revoke all on function public.allocate_payment_for_admin(uuid,uuid,bigint) from public;
revoke all on function public.prepare_payout_for_admin(uuid) from public;
revoke all on function public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,bigint) from public;
revoke all on function public.audit_financial_ledger_for_admin() from public;
revoke all on function public.refresh_membership_exit_financials_for_admin(uuid) from public;

grant execute on function public.create_payment_for_admin(uuid,bigint,timestamptz,public.payment_method,text,text) to authenticated;
grant execute on function public.list_payments_for_admin() to authenticated;
grant execute on function public.get_payment_for_admin(uuid) to authenticated;
grant execute on function public.list_payment_allocations_for_admin(uuid) to authenticated;
grant execute on function public.allocate_payment_for_admin(uuid,uuid,bigint) to authenticated;
grant execute on function public.prepare_payout_for_admin(uuid) to authenticated;
grant execute on function public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,bigint) to authenticated;
grant execute on function public.audit_financial_ledger_for_admin() to authenticated;
grant execute on function public.refresh_membership_exit_financials_for_admin(uuid) to authenticated;

commit;
