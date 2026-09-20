begin;

create or replace function public.create_membership_exit_for_admin(
  target_membership_id uuid,
  exit_reason public.settlement_reason,
  target_exit_date date,
  target_refund_policy public.refund_policy default 'AT_MATURITY',
  target_refund_amount bigint default null,
  target_notes text default null
)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  target_kuri_id uuid;
  target_person_id uuid;
  contributed_amount bigint:=0;
  calculated_refund bigint;
  exit_id_value uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select m.kuri_id,m.person_id into target_kuri_id,target_person_id
  from public.memberships m
  join public.kuris k on k.id=m.kuri_id
  where m.id=target_membership_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );

  if target_kuri_id is null then raise exception 'Membership not found or access denied.'; end if;

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
  )
  values(
    target_membership_id,exit_reason,target_exit_date,target_refund_policy,
    contributed_amount,calculated_refund,'PENDING',nullif(btrim(target_notes),'')
  )
  returning id into exit_id_value;

  update public.memberships set status='EXITED' where id=target_membership_id;

  return exit_id_value;
end;
$$;

revoke all on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text) from public;
grant execute on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text) to authenticated;

commit;