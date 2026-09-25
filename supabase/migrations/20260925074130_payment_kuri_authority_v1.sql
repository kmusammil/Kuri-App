begin;

-- Payment records must belong to one Kuri so payment visibility and mutation
-- can be enforced at the same tenant boundary as membership/installments.
alter table public.payments
  add column if not exists kuri_id uuid;

do $$
declare
  unresolved_count integer;
  multi_kuri_count integer;
begin
  select count(*) into multi_kuri_count
  from (
    select pa.payment_id
    from public.payment_allocations pa
    join public.installments i on i.id=pa.installment_id
    join public.memberships m on m.id=i.membership_id
    join public.kuris k on k.id=m.kuri_id
    group by pa.payment_id
    having count(distinct k.id)>1
  ) x;

  if multi_kuri_count>0 then
    raise exception
      'Cannot backfill payments.kuri_id: % payment(s) have allocations across multiple Kuris.',
      multi_kuri_count;
  end if;

  update public.payments p
  set kuri_id=x.kuri_id
  from (
    select pa.payment_id, (array_agg(k.id order by k.id))[1] as kuri_id
    from public.payment_allocations pa
    join public.installments i on i.id=pa.installment_id
    join public.memberships m on m.id=i.membership_id
    join public.kuris k on k.id=m.kuri_id
    group by pa.payment_id
  ) x
  where p.id=x.payment_id and p.kuri_id is null;

  update public.payments p
  set kuri_id=x.kuri_id
  from (
    select p2.id, (array_agg(k.id order by k.id))[1] as kuri_id
    from public.payments p2
    join public.memberships m on m.person_id=p2.person_id
    join public.kuris k on k.id=m.kuri_id
    where k.organization_id=p2.organization_id
    group by p2.id
    having count(distinct k.id)=1
  ) x
  where p.id=x.id and p.kuri_id is null;

  select count(*) into unresolved_count
  from public.payments
  where kuri_id is null;

  if unresolved_count>0 then
    raise exception
      'Cannot make payments.kuri_id NOT NULL: % payment(s) have no unambiguous Kuri.',
      unresolved_count;
  end if;
end $$;

alter table public.kuris
  add constraint kuris_id_organization_id_key unique (id,organization_id);

alter table public.payments
  alter column kuri_id set not null;

alter table public.payments
  add constraint payments_kuri_id_fkey
  foreign key (kuri_id) references public.kuris(id);

alter table public.payments
  add constraint payments_kuri_organization_fkey
  foreign key (kuri_id,organization_id)
  references public.kuris(id,organization_id);

-- Replace organization-wide payment admin APIs with explicit Kuri-scoped APIs.
drop function public.create_payment_for_admin(uuid,bigint,timestamptz,public.payment_method,text,text);
drop function public.list_payments_for_admin();
drop function public.get_payment_for_admin(uuid);
drop function public.list_installments_for_person_payment_admin(uuid);
drop function public.list_installments_for_payment_admin(uuid);
drop function public.list_installments_for_cycle_admin(uuid);
drop function public.list_payment_allocations_for_admin(uuid);
drop function public.allocate_payment_for_admin(uuid,uuid,bigint);
drop function public.audit_financial_ledger_for_admin();
drop function public.refresh_membership_exit_financials_for_admin(uuid);

create function public.create_payment_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  payment_amount bigint,
  payment_date timestamptz,
  payment_method public.payment_method,
  payment_reference text default null,
  payment_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  payment_id uuid;
  target_org_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if payment_amount<=0 then raise exception 'Payment amount must be greater than zero.'; end if;

  select k.organization_id into target_org_id
  from public.kuris k
  where k.id=target_kuri_id;

  if target_org_id is null then raise exception 'Kuri not found.'; end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to record payments for this Kuri.';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.kuri_id=target_kuri_id
      and m.person_id=target_person_id
  ) then
    raise exception 'Person is not a member of this Kuri.';
  end if;

  insert into public.payments(
    kuri_id,organization_id,person_id,amount,payment_date,method,
    reference_number,status,notes
  )
  values(
    target_kuri_id,target_org_id,target_person_id,payment_amount,payment_date,
    payment_method,nullif(btrim(payment_reference),''),
    'APPROVED',nullif(btrim(payment_notes),'')
  )
  returning id into payment_id;

  return payment_id;
end $$;

create function public.list_payments_for_admin(target_kuri_id uuid)
returns table(
  id uuid,
  person_id uuid,
  registered_name text,
  display_name text,
  amount bigint,
  payment_date timestamptz,
  method public.payment_method,
  reference_number text,
  status public.payment_status
)
language sql
security definer
set search_path=public
stable
as $$
  select p.id,p.person_id,pe.registered_name,pe.display_name,p.amount,
         p.payment_date,p.method,p.reference_number,p.status
  from public.payments p
  join public.people pe on pe.id=p.person_id
  where p.kuri_id=target_kuri_id
    and public.has_kuri_admin_role(
      target_kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by p.payment_date desc,p.created_at desc;
$$;

create function public.get_payment_for_admin(target_payment_id uuid)
returns table(
  id uuid,
  person_id uuid,
  registered_name text,
  display_name text,
  amount bigint,
  payment_date timestamptz,
  method public.payment_method,
  reference_number text,
  status public.payment_status,
  notes text,
  submitted_at timestamptz,
  verified_at timestamptz
)
language sql
security definer
set search_path=public
stable
as $$
  select p.id,p.person_id,pe.registered_name,pe.display_name,p.amount,
         p.payment_date,p.method,p.reference_number,p.status,p.notes,
         p.submitted_at,p.verified_at
  from public.payments p
  join public.people pe on pe.id=p.person_id
  where p.id=target_payment_id
    and public.has_kuri_admin_role(
      p.kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );
$$;

create function public.list_installments_for_person_payment_admin(
  target_kuri_id uuid,
  target_person_id uuid
)
returns table(
  id uuid,
  kuri_id uuid,
  kuri_name text,
  membership_id uuid,
  membership_number text,
  cycle_id uuid,
  cycle_number integer,
  amount_due bigint,
  amount_paid bigint,
  balance bigint,
  status public.installment_status,
  due_date date
)
language sql
security definer
set search_path=public
stable
as $$
  select i.id,k.id,k.name,m.id,m.membership_number,c.id,c.cycle_number,
         i.amount_due,i.amount_paid,greatest(i.amount_due-i.amount_paid,0),
         i.status,i.due_date
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where m.person_id=target_person_id
    and k.id=target_kuri_id
    and greatest(i.amount_due-i.amount_paid,0)>0
    and public.has_kuri_admin_role(
      target_kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by c.cycle_number,m.membership_number;
$$;

create function public.list_installments_for_payment_admin(target_kuri_id uuid)
returns table(
  id uuid,
  membership_id uuid,
  membership_number text,
  registered_name text,
  display_name text,
  cycle_id uuid,
  cycle_number integer,
  amount_due bigint,
  amount_paid bigint,
  balance bigint,
  status public.installment_status,
  due_date date
)
language sql
security definer
set search_path=public
stable
as $$
  select i.id,i.membership_id,m.membership_number,p.registered_name,
         p.display_name,i.cycle_id,c.cycle_number,i.amount_due,i.amount_paid,
         greatest(i.amount_due-i.amount_paid,0),i.status,i.due_date
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.people p on p.id=m.person_id
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where k.id=target_kuri_id
    and public.has_kuri_admin_role(
      target_kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by c.cycle_number,m.membership_number;
$$;

create function public.list_installments_for_cycle_admin(target_cycle_id uuid)
returns table(
  id uuid,
  membership_id uuid,
  membership_number text,
  registered_name text,
  display_name text,
  amount_due bigint,
  amount_paid bigint,
  status public.installment_status,
  due_date date
)
language sql
security definer
set search_path=public
stable
as $$
  select i.id,i.membership_id,m.membership_number,p.registered_name,
         p.display_name,i.amount_due,i.amount_paid,i.status,i.due_date
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.people p on p.id=m.person_id
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where i.cycle_id=target_cycle_id
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by m.membership_number;
$$;

create function public.list_payment_allocations_for_admin(target_payment_id uuid)
returns table(
  id uuid,
  installment_id uuid,
  kuri_id uuid,
  kuri_name text,
  cycle_number integer,
  membership_number text,
  amount bigint
)
language sql
security definer
set search_path=public
stable
as $$
  select pa.id,i.id,k.id,k.name,c.cycle_number,m.membership_number,pa.amount
  from public.payment_allocations pa
  join public.payments p on p.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  join public.memberships m on m.id=i.membership_id
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where pa.payment_id=target_payment_id
    and p.kuri_id=k.id
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by c.cycle_number,m.membership_number;
$$;

create function public.allocate_payment_for_admin(
  target_payment_id uuid,
  target_installment_id uuid,
  allocation_amount bigint
)
returns bigint
language plpgsql
security definer
set search_path=public
as $$
declare
  payment_person_id uuid;
  payment_total bigint;
  payment_status public.payment_status;
  payment_kuri_id uuid;
  installment_person_id uuid;
  installment_amount_due bigint;
  target_kuri_id uuid;
  already_allocated bigint;
  installment_allocated bigint;
  next_paid bigint;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if allocation_amount<=0 then raise exception 'Allocation amount must be greater than zero.'; end if;

  select p.person_id,p.amount,p.status,p.kuri_id
    into payment_person_id,payment_total,payment_status,payment_kuri_id
  from public.payments p
  where p.id=target_payment_id
  for update;

  if not found then raise exception 'Payment not found.'; end if;

  select i.amount_due,m.person_id,k.id
    into installment_amount_due,installment_person_id,target_kuri_id
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.kuris k on k.id=m.kuri_id
  where i.id=target_installment_id
  for update;

  if not found then raise exception 'Installment not found.'; end if;
  if payment_person_id<>installment_person_id then
    raise exception 'Payment person does not match installment person.';
  end if;
  if payment_kuri_id<>target_kuri_id then
    raise exception 'Payment and installment belong to different Kuris.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
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

  insert into public.payment_allocations(payment_id,installment_id,amount,allocated_by)
  values(
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

create function public.audit_financial_ledger_for_admin(target_kuri_id uuid)
returns table(
  approved_payment_total bigint,
  allocation_total bigint,
  installment_paid_total bigint,
  unallocated_approved_payment bigint,
  installment_allocation_gap bigint
)
language plpgsql
security definer
set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to audit this Kuri financial ledger.';
  end if;

  return query
  with approved as (
    select coalesce(sum(p.amount),0) total
    from public.payments p
    where p.status='APPROVED'
      and p.kuri_id=target_kuri_id
  ),
  allocated as (
    select coalesce(sum(pa.amount),0) total
    from public.payment_allocations pa
    join public.payments p on p.id=pa.payment_id
    where p.kuri_id=target_kuri_id
  ),
  installment_paid as (
    select coalesce(sum(i.amount_paid),0) total
    from public.installments i
    join public.memberships m on m.id=i.membership_id
    where m.kuri_id=target_kuri_id
  )
  select approved.total,allocated.total,installment_paid.total,
         greatest(approved.total-allocated.total,0),
         greatest(installment_paid.total-allocated.total,0)
  from approved,allocated,installment_paid;
end $$;

create function public.refresh_membership_exit_financials_for_admin(target_exit_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  target_kuri_id uuid;
  target_membership_id uuid;
  contributed_amount bigint:=0;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.id,me.membership_id
    into target_kuri_id,target_membership_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id;

  if target_kuri_id is null then raise exception 'Exit record not found.'; end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to refresh this exit.';
  end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id
    and pay.status='APPROVED'
    and pay.kuri_id=target_kuri_id;

  update public.membership_exits me
  set amount_contributed=contributed_amount,
      refund_amount=case
        when coalesce(me.refund_amount,0)=0 then contributed_amount
        else least(me.refund_amount,contributed_amount)
      end
  where me.id=target_exit_id;
end $$;

drop policy if exists payments_select on public.payments;
create policy payments_select
  on public.payments
  for select
  to public
  using (
    exists (
      select 1
      from public.users u
      where u.id=(select auth.uid())
        and u.person_id=payments.person_id
    )
    or public.has_kuri_admin_role(
      payments.kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  );

drop policy if exists payment_allocations_select on public.payment_allocations;
create policy payment_allocations_select
  on public.payment_allocations
  for select
  to public
  using (
    exists (
      select 1
      from public.installments i
      join public.memberships m on m.id=i.membership_id
      join public.kuris k on k.id=m.kuri_id
      where i.id=payment_allocations.installment_id
        and (
          exists (
            select 1
            from public.users u
            where u.id=(select auth.uid())
              and u.person_id=m.person_id
          )
          or public.has_kuri_admin_role(
            k.id,
            array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
          )
        )
    )
  );

revoke all on function public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text) from public;
revoke all on function public.list_payments_for_admin(uuid) from public;
revoke all on function public.get_payment_for_admin(uuid) from public;
revoke all on function public.list_installments_for_person_payment_admin(uuid,uuid) from public;
revoke all on function public.list_installments_for_payment_admin(uuid) from public;
revoke all on function public.list_installments_for_cycle_admin(uuid) from public;
revoke all on function public.list_payment_allocations_for_admin(uuid) from public;
revoke all on function public.allocate_payment_for_admin(uuid,uuid,bigint) from public;
revoke all on function public.audit_financial_ledger_for_admin(uuid) from public;
revoke all on function public.refresh_membership_exit_financials_for_admin(uuid) from public;

grant execute on function public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text) to authenticated;
grant execute on function public.list_payments_for_admin(uuid) to authenticated;
grant execute on function public.get_payment_for_admin(uuid) to authenticated;
grant execute on function public.list_installments_for_person_payment_admin(uuid,uuid) to authenticated;
grant execute on function public.list_installments_for_payment_admin(uuid) to authenticated;
grant execute on function public.list_installments_for_cycle_admin(uuid) to authenticated;
grant execute on function public.list_payment_allocations_for_admin(uuid) to authenticated;
grant execute on function public.allocate_payment_for_admin(uuid,uuid,bigint) to authenticated;
grant execute on function public.audit_financial_ledger_for_admin(uuid) to authenticated;
grant execute on function public.refresh_membership_exit_financials_for_admin(uuid) to authenticated;

commit;