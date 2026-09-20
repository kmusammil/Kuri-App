begin;

create or replace function public.approve_membership_exit_for_admin(target_exit_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  target_org_id uuid;
  target_membership_id uuid;
  contributed_amount bigint := 0;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id, me.membership_id
    into target_org_id, target_membership_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id and me.status='PENDING';

  if target_org_id is null then raise exception 'Pending exit not found.'; end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to approve this exit.'; end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id and pay.status='APPROVED';

  update public.membership_exits
  set amount_contributed=contributed_amount,
      refund_amount=case
        when coalesce(refund_amount,0)=0 then contributed_amount
        else least(refund_amount, contributed_amount)
      end,
      status='APPROVED',
      approved_by=(select id from public.users where id=auth.uid())
  where id=target_exit_id and status='PENDING';

  if not found then raise exception 'Exit is no longer pending.'; end if;
end;
$$;

revoke all on function public.approve_membership_exit_for_admin(uuid) from public;
grant execute on function public.approve_membership_exit_for_admin(uuid) to authenticated;

commit;
