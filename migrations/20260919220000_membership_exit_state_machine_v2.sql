begin;

-- Membership exit lifecycle hardening.
-- Exit creation: ACTIVE/SUSPENDED membership -> PENDING exit + EXITED membership.
-- Approval: PENDING -> APPROVED.
-- Settlement: APPROVED -> SETTLED.
-- Immediate refund and death settlement now use the guarded transition.
-- Historical rows are preserved.

create or replace function public.create_membership_exit_for_admin(
  target_membership_id uuid,
  exit_reason public.settlement_reason,
  target_exit_date date,
  target_refund_policy public.refund_policy default 'AT_MATURITY',
  target_refund_amount bigint default null,
  target_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  target_kuri_id uuid;
  target_person_id uuid;
  current_membership_status public.membership_status;
  contributed_amount bigint:=0;
  calculated_refund bigint;
  exit_id_value uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if target_exit_date is null then raise exception 'Exit date is required.'; end if;

  select m.kuri_id,m.person_id,m.status
    into target_kuri_id,target_person_id,current_membership_status
  from public.memberships m
  join public.kuris k on k.id=m.kuri_id
  where m.id=target_membership_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  for update;

  if target_kuri_id is null then raise exception 'Membership not found or access denied.'; end if;
  if current_membership_status not in ('ACTIVE','SUSPENDED') then
    raise exception 'Only ACTIVE or SUSPENDED memberships can be exited.';
  end if;

  if exists (
    select 1 from public.membership_exits me
    where me.membership_id=target_membership_id and me.status<>'CANCELLED'
  ) then
    raise exception 'An active exit record already exists for this membership.';
  end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id and pay.status='APPROVED';

  calculated_refund:=case
    when target_refund_amount is null then contributed_amount
    else greatest(target_refund_amount,0)
  end;

  insert into public.membership_exits(
    membership_id,reason,exit_date,refund_policy,amount_contributed,refund_amount,status,notes
  ) values(
    target_membership_id,exit_reason,target_exit_date,target_refund_policy,
    contributed_amount,calculated_refund,'PENDING',nullif(btrim(target_notes),'')
  )
  returning id into exit_id_value;

  perform public.transition_membership_status_for_admin(target_membership_id,'EXITED');

  return exit_id_value;
end;
$$;

create or replace function public.approve_membership_exit_for_admin(target_exit_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  target_org_id uuid;
  target_membership_id uuid;
  contributed_amount bigint:=0;
  existing_status public.settlement_status;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id,me.membership_id,me.status
    into target_org_id,target_membership_id,existing_status
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
  for update;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to approve this exit.'; end if;
  if existing_status<>'PENDING' then raise exception 'Exit is not pending approval.'; end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id and pay.status='APPROVED';

  update public.membership_exits
  set amount_contributed=contributed_amount,
      refund_amount=case when coalesce(refund_amount,0)=0 then contributed_amount else least(refund_amount,contributed_amount) end,
      approved_by=(select id from public.users where id=auth.uid())
  where id=target_exit_id and status='PENDING';

  if not found then raise exception 'Exit is no longer pending.'; end if;

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'APPROVED');
end;
$$;

create or replace function public.record_membership_exit_refund_for_admin(
  target_exit_id uuid,
  refund_amount bigint,
  refund_payment_method public.payment_method,
  refund_reference text default null,
  refund_paid_at timestamptz default null,
  refund_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  target_org_id uuid;
  expected_refund bigint;
  existing_paid bigint:=0;
  transaction_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if refund_amount<=0 then raise exception 'Refund amount must be greater than zero.'; end if;

  select k.organization_id,me.refund_amount
    into target_org_id,expected_refund
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
  for update;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to record this refund.'; end if;
  if not exists (
    select 1 from public.membership_exits me
    where me.id=target_exit_id and me.status='APPROVED' and me.refund_policy='IMMEDIATE'
  ) then raise exception 'Only approved immediate refunds can be paid here.'; end if;

  select coalesce(rt.amount,0) into existing_paid
  from public.membership_exit_refund_transactions rt
  where rt.membership_exit_id=target_exit_id
  for update;

  if existing_paid>0 then raise exception 'A refund transaction already exists for this exit.'; end if;
  if refund_amount>expected_refund then raise exception 'Refund exceeds the approved refund amount.'; end if;

  insert into public.membership_exit_refund_transactions(
    membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
  ) values(
    target_exit_id,refund_amount,refund_payment_method,nullif(btrim(refund_reference),''),
    coalesce(refund_paid_at,now()),(select id from public.users where id=auth.uid()),
    nullif(btrim(refund_notes),'')
  ) returning id into transaction_id;

  if refund_amount=expected_refund then
    perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');
  end if;

  return transaction_id;
end;
$$;

create or replace function public.settle_membership_exit_for_admin(
  target_exit_id uuid,
  settlement_payment_method public.muppu_settlement_method default 'PAID_IN_ADVANCE',
  settlement_reference text default null,
  settlement_date timestamptz default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  target_org_id uuid;
  target_status public.settlement_status;
  target_policy public.refund_policy;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id,me.status,me.refund_policy
    into target_org_id,target_status,target_policy
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
  for update;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to settle this exit.'; end if;
  if target_status<>'APPROVED' then raise exception 'Exit must be approved before settlement.'; end if;
  if settlement_payment_method='PAID_IN_ADVANCE' then
    raise exception 'Use the refund payment action to record an immediate refund.';
  end if;
  if target_policy='IMMEDIATE' then
    raise exception 'Immediate refunds must be settled through the refund transaction action.';
  end if;

  update public.membership_exits
  set notes=concat_ws(' | ',notes,'Settled without immediate cash refund: ',coalesce(settlement_reference,''))
  where id=target_exit_id and status='APPROVED';

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');
end;
$$;

create or replace function public.record_death_settlement_for_admin(
  target_exit_id uuid,
  target_nominee_id uuid default null,
  settlement_notes text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org_id uuid;
  v_person_id uuid;
  v_refund_amount bigint:=0;
  v_status public.settlement_status;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id,m.person_id,coalesce(me.refund_amount,0),me.status
    into v_org_id,v_person_id,v_refund_amount,v_status
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id and me.reason='DEATH'
  for update;

  if v_org_id is null then raise exception 'Death exit record not found.'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=v_org_id and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to settle this death case.'; end if;
  if v_status<>'APPROVED' then raise exception 'Death exit must be approved before settlement.'; end if;
  if target_nominee_id is null then raise exception 'A nominee must be selected before settlement.'; end if;
  if not exists(select 1 from public.nominees n where n.id=target_nominee_id and n.person_id=v_person_id) then
    raise exception 'Selected nominee does not belong to this person.';
  end if;
  if v_refund_amount>0 and exists(select 1 from public.membership_exit_refund_transactions rt where rt.membership_exit_id=target_exit_id) then
    raise exception 'A refund transaction already exists for this death exit.';
  end if;

  if v_refund_amount>0 then
    insert into public.membership_exit_refund_transactions(
      membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
    ) values(
      target_exit_id,v_refund_amount,'OTHER',null,now(),
      (select id from public.users where id=auth.uid()),
      'Death settlement refund to nominee: ' ||
      coalesce((select n.name from public.nominees n where n.id=target_nominee_id),'Nominee')
    );
  end if;

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');

  update public.membership_exits
  set settled_to_nominee_id=target_nominee_id,
      settlement_notes=nullif(btrim(record_death_settlement_for_admin.settlement_notes),'')
  where id=target_exit_id;
end;
$$;

revoke all on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text) from public;
revoke all on function public.approve_membership_exit_for_admin(uuid) from public;
revoke all on function public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text) from public;
revoke all on function public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz) from public;
revoke all on function public.record_death_settlement_for_admin(uuid,uuid,text) from public;

grant execute on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text) to authenticated;
grant execute on function public.approve_membership_exit_for_admin(uuid) to authenticated;
grant execute on function public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text) to authenticated;
grant execute on function public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz) to authenticated;
grant execute on function public.record_death_settlement_for_admin(uuid,uuid,text) to authenticated;

commit;
