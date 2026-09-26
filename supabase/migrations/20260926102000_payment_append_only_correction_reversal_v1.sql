-- PAYMENT-001: Append-only payment correction/reversal
-- Original payments and applied correction/reversal ledger entries are immutable.
-- Corrections and reversals are represented by new append-only records.

create or replace function public.enforce_payment_append_only()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception 'Financial payment records are append-only and cannot be deleted.';
  end if;

  raise exception 'Financial payment records are append-only and cannot be updated. Use the correction or reversal workflow.';
end;
$function$;

drop trigger if exists payments_append_only on public.payments;
create trigger payments_append_only
before update or delete on public.payments
for each row
execute function public.enforce_payment_append_only();

drop trigger if exists payment_corrections_append_only on public.payment_corrections;
create trigger payment_corrections_append_only
before update or delete on public.payment_corrections
for each row
execute function public.enforce_payment_append_only();

drop trigger if exists payment_reversal_entries_append_only on public.payment_reversal_entries;
create trigger payment_reversal_entries_append_only
before update or delete on public.payment_reversal_entries
for each row
execute function public.enforce_payment_append_only();

revoke all on function public.enforce_payment_append_only() from public, anon;
grant execute on function public.enforce_payment_append_only() to authenticated;