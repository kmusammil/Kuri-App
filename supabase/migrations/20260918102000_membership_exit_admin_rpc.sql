begin;

create or replace function public.list_membership_exits_for_admin(target_kuri_id uuid)
returns table (
  exit_id uuid,membership_id uuid,membership_number text,registered_name text,display_name text,
  reason public.settlement_reason,exit_date date,refund_policy public.refund_policy,
  amount_contributed bigint,refund_amount bigint,status public.settlement_status,
  approved_by uuid,settled_at timestamptz,notes text
)
language sql security definer set search_path=public stable
as $$
  select me.id,m.id,m.membership_number,p.registered_name,p.display_name,
         me.reason,me.exit_date,me.refund_policy,me.amount_contributed,
         me.refund_amount,me.status,me.approved_by,me.settled_at,me.notes
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.people p on p.id=m.person_id
  join public.kuris k on k.id=m.kuri_id
  where k.id=target_kuri_id
    and exists (select 1 from public.organization_users ou
                where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
                  and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]))
  order by me.exit_date desc,m.membership_number;
$$;

create or replace function public.create_membership_exit_for_admin(
  target_membership_id uuid,exit_reason public.settlement_reason,target_exit_date date,
  target_refund_policy public.refund_policy default 'AT_MATURITY',
  target_refund_amount bigint default null,target_notes text default null
)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare kuri_id_value uuid; contributed_amount bigint:=0; calculated_refund bigint; exit_id_value uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if target_exit_date is null then raise exception 'Exit date is required.'; end if;

  select m.kuri_id into kuri_id_value
  from public.memberships m join public.kuris k on k.id=m.kuri_id
  where m.id=target_membership_id
    and exists (select 1 from public.organization_users ou
                where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
                  and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]));

  if kuri_id_value is null then raise exception 'Membership not found or access denied.'; end if;

  if exists (select 1 from public.membership_exits me
             where me.membership_id=target_membership_id and me.status<>'CANCELLED') then
    raise exception 'An active exit record already exists for this membership.';
  end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id and pay.status='APPROVED';

  calculated_refund:=case when target_refund_amount is null then contributed_amount
                          else greatest(target_refund_amount,0) end;

  insert into public.membership_exits(
    membership_id,reason,exit_date,refund_policy,amount_contributed,refund_amount,status,notes
  ) values (
    target_membership_id,exit_reason,target_exit_date,target_refund_policy,
    contributed_amount,calculated_refund,'PENDING',nullif(btrim(target_notes),'')
  ) returning id into exit_id_value;

  update public.memberships set status='EXITED' where id=target_membership_id;

  return exit_id_value;
end;
$$;

create or replace function public.approve_membership_exit_for_admin(target_exit_id uuid)
returns void
language plpgsql security definer set search_path=public
as $$
declare target_org_id uuid;
begin
  select k.organization_id into target_org_id
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id where me.id=target_exit_id;
  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not exists (select 1 from public.organization_users ou
                 where ou.organization_id=target_org_id and ou.user_id=auth.uid()
                   and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then
    raise exception 'You do not have permission to approve this exit.';
  end if;
  update public.membership_exits set status='APPROVED',approved_by=(select id from public.users where id=auth.uid())
  where id=target_exit_id and status='PENDING';
  if not found then raise exception 'Exit is not pending approval.'; end if;
end;
$$;

create or replace function public.settle_membership_exit_for_admin(
  target_exit_id uuid,
  settlement_payment_method public.muppu_settlement_method default 'PAID_IN_ADVANCE',
  settlement_reference text default null,
  settlement_date timestamptz default null
)
returns void
language plpgsql security definer set search_path=public
as $$
declare target_org_id uuid;
begin
  select k.organization_id into target_org_id
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id where me.id=target_exit_id;
  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not exists (select 1 from public.organization_users ou
                 where ou.organization_id=target_org_id and ou.user_id=auth.uid()
                   and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then
    raise exception 'You do not have permission to settle this exit.';
  end if;
  update public.membership_exits set status='SETTLED',settled_at=coalesce(settlement_date,now())
  where id=target_exit_id and status='APPROVED';
  if not found then raise exception 'Exit must be approved before settlement.'; end if;
end;
$$;

revoke all on function public.list_membership_exits_for_admin(uuid) from public;
revoke all on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text) from public;
revoke all on function public.approve_membership_exit_for_admin(uuid) from public;
revoke all on function public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz) from public;

grant execute on function public.list_membership_exits_for_admin(uuid) to authenticated;
grant execute on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text) to authenticated;
grant execute on function public.approve_membership_exit_for_admin(uuid) to authenticated;
grant execute on function public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz) to authenticated;

commit;