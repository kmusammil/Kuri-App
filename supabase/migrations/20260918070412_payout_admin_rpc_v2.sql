begin;

create or replace function public.prepare_payout_for_admin(target_winner_id uuid)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare payout_id uuid; winner_person_id uuid; gross_amount bigint; muppu_amount bigint;
begin
  select mw.person_id,k.gross_prize_amount,k.muppu_amount
    into winner_person_id,gross_amount,muppu_amount
  from public.monthly_winners mw
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where mw.id=target_winner_id
    and exists (select 1 from public.organization_users ou where ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]));
  if winner_person_id is null then raise exception 'Monthly winner not found.'; end if;
  if gross_amount<=0 then raise exception 'Gross prize amount must be greater than zero.'; end if;
  select po.id into payout_id from public.payouts po where po.monthly_winner_id=target_winner_id;
  if payout_id is null then
    insert into public.payouts(monthly_winner_id,gross_amount,muppu_amount,other_deductions,net_amount,status)
    values(target_winner_id,gross_amount,coalesce(muppu_amount,0),0,greatest(gross_amount-coalesce(muppu_amount,0),0),'PENDING')
    returning id into payout_id;
  end if;
  return payout_id;
end;
$$;

create or replace function public.get_payout_for_admin(target_winner_id uuid)
returns table (payout_id uuid,winner_id uuid,person_id uuid,registered_name text,display_name text,gross_amount bigint,muppu_amount bigint,other_deductions bigint,net_amount bigint,payment_date timestamptz,method public.payment_method,reference_number text,status public.payout_status,processed_by uuid,notes text,created_at timestamptz)
language sql security definer set search_path=public stable
as $$
  select po.id,mw.id,mw.person_id,p.registered_name,p.display_name,po.gross_amount,po.muppu_amount,po.other_deductions,po.net_amount,po.payment_date,po.method,po.reference_number,po.status,po.processed_by,po.notes,po.created_at
  from public.payouts po join public.monthly_winners mw on mw.id=po.monthly_winner_id join public.people p on p.id=mw.person_id join public.cycles c on c.id=mw.cycle_id join public.kuris k on k.id=c.kuri_id
  where mw.id=target_winner_id and exists (select 1 from public.organization_users ou where ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]));
$$;

create or replace function public.list_payouts_for_admin(target_kuri_id uuid default null)
returns table (payout_id uuid,winner_id uuid,cycle_number integer,person_id uuid,registered_name text,display_name text,gross_amount bigint,muppu_amount bigint,other_deductions bigint,net_amount bigint,payment_date timestamptz,method public.payment_method,reference_number text,status public.payout_status)
language sql security definer set search_path=public stable
as $$
  select po.id,mw.id,c.cycle_number,mw.person_id,p.registered_name,p.display_name,po.gross_amount,po.muppu_amount,po.other_deductions,po.net_amount,po.payment_date,po.method,po.reference_number,po.status
  from public.payouts po join public.monthly_winners mw on mw.id=po.monthly_winner_id join public.people p on p.id=mw.person_id join public.cycles c on c.id=mw.cycle_id join public.kuris k on k.id=c.kuri_id
  where (target_kuri_id is null or k.id=target_kuri_id)
    and exists (select 1 from public.organization_users ou where ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]))
  order by c.cycle_number desc,po.created_at desc;
$$;

create or replace function public.mark_payout_paid_for_admin(target_winner_id uuid,payout_payment_date timestamptz,payout_method public.payment_method,payout_reference text default null,payout_notes text default null,payout_other_deductions bigint default 0)
returns void
language plpgsql security definer set search_path=public
as $$
declare payout_row public.payouts%rowtype; target_org_id uuid; calculated_net bigint;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if payout_other_deductions<0 then raise exception 'Other deductions cannot be negative.'; end if;

  select po.* into payout_row from public.payouts po where po.monthly_winner_id=target_winner_id;
  if not found then
    perform public.prepare_payout_for_admin(target_winner_id);
    select po.* into payout_row from public.payouts po where po.monthly_winner_id=target_winner_id;
  end if;

  select k.organization_id into target_org_id
  from public.monthly_winners mw join public.cycles c on c.id=mw.cycle_id join public.kuris k on k.id=c.kuri_id
  where mw.id=target_winner_id;
  if target_org_id is null then raise exception 'Monthly winner not found.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=target_org_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to process this payout.'; end if;

  calculated_net:=greatest(payout_row.gross_amount-payout_row.muppu_amount-payout_other_deductions,0);
  update public.payouts
  set other_deductions=payout_other_deductions,net_amount=calculated_net,payment_date=coalesce(payout_payment_date,now()),method=payout_method,reference_number=nullif(btrim(payout_reference),''),status='PAID',processed_by=(select id from public.users where id=auth.uid()),notes=nullif(btrim(payout_notes),'')
  where id=payout_row.id;
end;
$$;

revoke all on function public.prepare_payout_for_admin(uuid) from public;
revoke all on function public.get_payout_for_admin(uuid) from public;
revoke all on function public.list_payouts_for_admin(uuid) from public;
revoke all on function public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,bigint) from public;

grant execute on function public.prepare_payout_for_admin(uuid) to authenticated;
grant execute on function public.get_payout_for_admin(uuid) to authenticated;
grant execute on function public.list_payouts_for_admin(uuid) to authenticated;
grant execute on function public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,bigint) to authenticated;

commit;