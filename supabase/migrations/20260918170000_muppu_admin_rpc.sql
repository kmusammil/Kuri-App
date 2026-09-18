begin;

create or replace function public.list_muppu_records_for_admin(target_kuri_id uuid default null,target_cycle_id uuid default null)
returns table(muppu_id uuid,kuri_id uuid,kuri_name text,cycle_id uuid,cycle_number integer,person_id uuid,registered_name text,display_name text,amount bigint,status public.muppu_status,settlement_method public.muppu_settlement_method,paid_at timestamptz,payment_reference text,created_at timestamptz)
language sql security definer set search_path=public stable
as $function$
select mr.id,mr.kuri_id,k.name,mr.cycle_id,c.cycle_number,mr.person_id,p.registered_name,p.display_name,mr.amount,mr.status,mr.settlement_method,mr.paid_at,mr.payment_reference,mr.created_at
from public.muppu_records mr join public.kuris k on k.id=mr.kuri_id join public.cycles c on c.id=mr.cycle_id join public.people p on p.id=mr.person_id
where (target_kuri_id is null or mr.kuri_id=target_kuri_id) and (target_cycle_id is null or mr.cycle_id=target_cycle_id)
and exists(select 1 from public.organization_users ou where ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]))
order by c.cycle_number desc,p.display_name,p.registered_name;
$function$;

create or replace function public.create_muppu_record_for_admin(target_kuri_id uuid,target_cycle_id uuid,target_person_id uuid,target_amount bigint)
returns uuid language plpgsql security definer set search_path=public as $function$
declare v_org_id uuid; v_id uuid;
begin
if auth.uid() is null then raise exception 'You must be signed in.'; end if;
if target_amount<0 then raise exception 'Muppu amount cannot be negative.'; end if;
select k.organization_id into v_org_id from public.kuris k join public.cycles c on c.kuri_id=k.id and c.id=target_cycle_id where k.id=target_kuri_id;
if v_org_id is null then raise exception 'Kuri or cycle not found.'; end if;
if not exists(select 1 from public.organization_users ou where ou.organization_id=v_org_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to manage Muppu.'; end if;
if not exists(select 1 from public.people where id=target_person_id) then raise exception 'Person not found.'; end if;
insert into public.muppu_records(kuri_id,cycle_id,person_id,amount,status) values(target_kuri_id,target_cycle_id,target_person_id,target_amount,'UNPAID') returning id into v_id;
return v_id;
end;
$function$;

create or replace function public.mark_muppu_paid_for_admin(target_muppu_id uuid,paid_payment_reference text default null,paid_at_value timestamptz default null)
returns void language plpgsql security definer set search_path=public as $function$
declare v_org_id uuid;
begin
if auth.uid() is null then raise exception 'You must be signed in.'; end if;
select k.organization_id into v_org_id from public.muppu_records mr join public.kuris k on k.id=mr.kuri_id where mr.id=target_muppu_id;
if v_org_id is null then raise exception 'Muppu record not found.'; end if;
if not exists(select 1 from public.organization_users ou where ou.organization_id=v_org_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to manage Muppu.'; end if;
update public.muppu_records mr set status='PAID',settlement_method='PAID_IN_ADVANCE',paid_at=coalesce(paid_at_value,now()),payment_reference=nullif(btrim(paid_payment_reference),'') where mr.id=target_muppu_id and mr.status='UNPAID';
if not found then raise exception 'Only unpaid Muppu records can be marked paid.'; end if;
end;
$function$;

create or replace function public.waive_muppu_for_admin(target_muppu_id uuid,waiver_reference text default null)
returns void language plpgsql security definer set search_path=public as $function$
declare v_org_id uuid;
begin
if auth.uid() is null then raise exception 'You must be signed in.'; end if;
select k.organization_id into v_org_id from public.muppu_records mr join public.kuris k on k.id=mr.kuri_id where mr.id=target_muppu_id;
if v_org_id is null then raise exception 'Muppu record not found.'; end if;
if not exists(select 1 from public.organization_users ou where ou.organization_id=v_org_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to manage Muppu.'; end if;
update public.muppu_records mr set status='WAIVED',settlement_method='WAIVED',payment_reference=nullif(btrim(waiver_reference),'') where mr.id=target_muppu_id and mr.status='UNPAID';
if not found then raise exception 'Only unpaid Muppu records can be waived.'; end if;
end;
$function$;

create or replace function public.deduct_muppu_from_prize_for_admin(target_muppu_id uuid,deduction_reference text default null)
returns void language plpgsql security definer set search_path=public as $function$
declare v_org_id uuid;
begin
if auth.uid() is null then raise exception 'You must be signed in.'; end if;
select k.organization_id into v_org_id from public.muppu_records mr join public.kuris k on k.id=mr.kuri_id where mr.id=target_muppu_id;
if v_org_id is null then raise exception 'Muppu record not found.'; end if;
if not exists(select 1 from public.organization_users ou where ou.organization_id=v_org_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to manage Muppu.'; end if;
update public.muppu_records mr set status='DEDUCTED',settlement_method='DEDUCTED_FROM_PRIZE',payment_reference=nullif(btrim(deduction_reference),'') where mr.id=target_muppu_id and mr.status='UNPAID';
if not found then raise exception 'Only unpaid Muppu records can be deducted.'; end if;
end;
$function$;

revoke all on function public.list_muppu_records_for_admin(uuid,uuid) from public;
revoke all on function public.create_muppu_record_for_admin(uuid,uuid,uuid,bigint) from public;
revoke all on function public.mark_muppu_paid_for_admin(uuid,text,timestamptz) from public;
revoke all on function public.waive_muppu_for_admin(uuid,text) from public;
revoke all on function public.deduct_muppu_from_prize_for_admin(uuid,text) from public;
grant execute on function public.list_muppu_records_for_admin(uuid,uuid) to authenticated;
grant execute on function public.create_muppu_record_for_admin(uuid,uuid,uuid,bigint) to authenticated;
grant execute on function public.mark_muppu_paid_for_admin(uuid,text,timestamptz) to authenticated;
grant execute on function public.waive_muppu_for_admin(uuid,text) to authenticated;
grant execute on function public.deduct_muppu_from_prize_for_admin(uuid,text) to authenticated;

commit;
