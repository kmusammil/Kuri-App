begin;

create or replace function public.record_death_settlement_for_admin(
  target_exit_id uuid,
  target_nominee_id uuid default null,
  settlement_notes text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_org_id uuid;
  v_person_id uuid;
  v_refund_amount bigint := 0;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id, m.person_id, coalesce(me.refund_amount,0)
    into v_org_id, v_person_id, v_refund_amount
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id and me.reason='DEATH';

  if v_org_id is null then raise exception 'Death exit record not found.'; end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=v_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to settle this death case.'; end if;

  if not exists (
    select 1 from public.membership_exits me
    where me.id=target_exit_id and me.status='APPROVED'
  ) then raise exception 'Death exit must be approved before settlement.'; end if;

  if target_nominee_id is null then raise exception 'A nominee must be selected before settlement.'; end if;

  if not exists (
    select 1 from public.nominees n
    where n.id=target_nominee_id and n.person_id=v_person_id
  ) then raise exception 'Selected nominee does not belong to this person.'; end if;

  if v_refund_amount > 0 and not exists (
    select 1 from public.membership_exit_refund_transactions rt
    where rt.membership_exit_id=target_exit_id
  ) then
    insert into public.membership_exit_refund_transactions(
      membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
    )
    values(
      target_exit_id,
      v_refund_amount,
      'OTHER'::public.payment_method,
      null,
      now(),
      (select u.id from public.users u where u.id=auth.uid()),
      'Death settlement refund to nominee: ' ||
        coalesce((select n.name from public.nominees n where n.id=target_nominee_id),'Nominee')
    );
  end if;

  update public.membership_exits me
  set status='SETTLED',
      settled_at=now(),
      settled_to_nominee_id=target_nominee_id,
      settlement_notes=nullif(btrim(record_death_settlement_for_admin.settlement_notes),'')
  where me.id=target_exit_id and me.status='APPROVED';

  if not found then raise exception 'Death exit must be approved before settlement.'; end if;
end;
$function$;

revoke all on function public.record_death_settlement_for_admin(uuid,uuid,text) from public;
grant execute on function public.record_death_settlement_for_admin(uuid,uuid,text) to authenticated;

commit;
