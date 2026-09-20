-- Harden financial audit logging for DELETE operations.
--
-- AFTER DELETE cannot reliably resolve organization_id through the row being
-- deleted. Financial audit events therefore use AFTER INSERT/UPDATE and
-- BEFORE DELETE triggers so related rows are still visible during DELETE
-- auditing. A signed-in actor's organization is a final fallback.

CREATE OR REPLACE FUNCTION public.audit_financial_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  actor_user_id uuid;
  org_id uuid;
  entity_id uuid;
  action_name text;
  old_payload jsonb;
  new_payload jsonb;
begin
  actor_user_id := auth.uid();

  if tg_op='DELETE' then
    entity_id := old.id;
    old_payload := to_jsonb(old);
    new_payload := null;
  else
    entity_id := new.id;
    old_payload := case when tg_op='UPDATE' then to_jsonb(old) else null end;
    new_payload := to_jsonb(new);
  end if;

  action_name := lower(tg_op);

  case tg_table_name
    when 'payments' then
      org_id := coalesce(new.organization_id,old.organization_id);
    when 'payment_allocations' then
      select p.organization_id into org_id
      from public.payments p
      where p.id=coalesce(new.payment_id,old.payment_id);
    when 'installments' then
      select k.organization_id into org_id
      from public.installments i
      join public.memberships m on m.id=i.membership_id
      join public.kuris k on k.id=m.kuri_id
      where i.id=coalesce(new.id,old.id);
    when 'membership_exits' then
      select k.organization_id into org_id
      from public.membership_exits e
      join public.memberships m on m.id=e.membership_id
      join public.kuris k on k.id=m.kuri_id
      where e.id=coalesce(new.id,old.id);
    when 'membership_exit_refund_transactions' then
      select k.organization_id into org_id
      from public.membership_exit_refund_transactions r
      join public.membership_exits e on e.id=r.membership_exit_id
      join public.memberships m on m.id=e.membership_id
      join public.kuris k on k.id=m.kuri_id
      where r.id=coalesce(new.id,old.id);
    when 'muppu_records' then
      select k.organization_id into org_id
      from public.muppu_records mr
      join public.kuris k on k.id=mr.kuri_id
      where mr.id=coalesce(new.id,old.id);
    when 'payouts' then
      select k.organization_id into org_id
      from public.payouts po
      join public.monthly_winners mw on mw.id=po.monthly_winner_id
      join public.cycles c on c.id=mw.cycle_id
      join public.kuris k on k.id=c.kuri_id
      where po.id=coalesce(new.id,old.id);
    else
      org_id := null;
  end case;

  if org_id is null and actor_user_id is not null then
    select ou.organization_id into org_id
    from public.organization_users ou
    where ou.user_id=actor_user_id
    order by case when ou.role in ('MAIN_ADMIN','ADMIN') then 0 else 1 end,
             ou.organization_id
    limit 1;
  end if;

  if org_id is null then
    raise exception 'Unable to resolve organization for financial audit event on %.%',
      tg_table_schema, tg_table_name;
  end if;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  values(
    org_id,actor_user_id,action_name,tg_table_name,entity_id,
    old_payload,new_payload,
    case when actor_user_id is null then 'system' else null end
  );

  return coalesce(new,old);
end;
$function$;

drop trigger if exists audit_installments on public.installments;
drop trigger if exists audit_installments_delete on public.installments;
create trigger audit_installments after insert or update on public.installments
for each row execute function public.audit_financial_change();
create trigger audit_installments_delete before delete on public.installments
for each row execute function public.audit_financial_change();

drop trigger if exists audit_membership_exit_refunds on public.membership_exit_refund_transactions;
drop trigger if exists audit_membership_exit_refunds_delete on public.membership_exit_refund_transactions;
create trigger audit_membership_exit_refunds after insert or update on public.membership_exit_refund_transactions
for each row execute function public.audit_financial_change();
create trigger audit_membership_exit_refunds_delete before delete on public.membership_exit_refund_transactions
for each row execute function public.audit_financial_change();

drop trigger if exists audit_membership_exits on public.membership_exits;
drop trigger if exists audit_membership_exits_delete on public.membership_exits;
create trigger audit_membership_exits after insert or update on public.membership_exits
for each row execute function public.audit_financial_change();
create trigger audit_membership_exits_delete before delete on public.membership_exits
for each row execute function public.audit_financial_change();

drop trigger if exists audit_muppu_records on public.muppu_records;
drop trigger if exists audit_muppu_records_delete on public.muppu_records;
create trigger audit_muppu_records after insert or update on public.muppu_records
for each row execute function public.audit_financial_change();
create trigger audit_muppu_records_delete before delete on public.muppu_records
for each row execute function public.audit_financial_change();

drop trigger if exists audit_payment_allocations on public.payment_allocations;
drop trigger if exists audit_payment_allocations_delete on public.payment_allocations;
create trigger audit_payment_allocations after insert or update on public.payment_allocations
for each row execute function public.audit_financial_change();
create trigger audit_payment_allocations_delete before delete on public.payment_allocations
for each row execute function public.audit_financial_change();

drop trigger if exists audit_payments on public.payments;
drop trigger if exists audit_payments_delete on public.payments;
create trigger audit_payments after insert or update on public.payments
for each row execute function public.audit_financial_change();
create trigger audit_payments_delete before delete on public.payments
for each row execute function public.audit_financial_change();

drop trigger if exists audit_payouts on public.payouts;
drop trigger if exists audit_payouts_delete on public.payouts;
create trigger audit_payouts after insert or update on public.payouts
for each row execute function public.audit_financial_change();
create trigger audit_payouts_delete before delete on public.payouts
for each row execute function public.audit_financial_change();
