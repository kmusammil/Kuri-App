begin;

drop policy if exists _state_machine_context_deny on public._state_machine_context;
create policy _state_machine_context_deny
on public._state_machine_context
as restrictive
for all
to public
using (false)
with check (false);

drop policy if exists membership_exit_refund_transactions_deny on public.membership_exit_refund_transactions;
create policy membership_exit_refund_transactions_deny
on public.membership_exit_refund_transactions
as restrictive
for all
to public
using (false)
with check (false);

commit;