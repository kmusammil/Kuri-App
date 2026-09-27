-- SEC-012/SEC-013 hardening: trigger-only functions must not be client-callable.
-- They execute only through table triggers and do not form part of the RPC API.

revoke execute on function public.enforce_membership_current_holder_identity() from anon, authenticated;
revoke execute on function public.enforce_membership_succession_identity() from anon, authenticated;
revoke execute on function public.prevent_membership_succession_mutation() from anon, authenticated;

revoke execute on function public.enforce_cycle_historical_immutability() from authenticated;
revoke execute on function public.enforce_payment_append_only() from authenticated;
revoke execute on function public.enforce_draw_pool_eligibility_freeze() from authenticated;
revoke execute on function public.enforce_finalized_winner_immutability() from authenticated;
revoke execute on function public.enforce_draw_pool_membership_history() from authenticated;
revoke execute on function public.enforce_kuri_lifecycle_mutation_lock() from authenticated;
