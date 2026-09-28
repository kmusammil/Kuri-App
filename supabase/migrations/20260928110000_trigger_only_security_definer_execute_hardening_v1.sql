-- SEC-012/SEC-013: trigger-only functions must not be client-callable.
-- These functions are invoked exclusively by table triggers and are not part of the RPC API.
-- Consolidates the public/authenticated execution hardening from the main-side
-- 20260927092000 and 20260927092100 migrations.

begin;

revoke execute on function public.enforce_membership_current_holder_identity() from public, anon, authenticated;
revoke execute on function public.enforce_membership_succession_identity() from public, anon, authenticated;
revoke execute on function public.prevent_membership_succession_mutation() from public, anon, authenticated;
revoke execute on function public.enforce_cycle_historical_immutability() from public, anon, authenticated;
revoke execute on function public.enforce_payment_append_only() from public, anon, authenticated;
revoke execute on function public.enforce_draw_pool_eligibility_freeze() from public, anon, authenticated;
revoke execute on function public.enforce_finalized_winner_immutability() from public, anon, authenticated;
revoke execute on function public.enforce_draw_pool_membership_history() from public, anon, authenticated;
revoke execute on function public.enforce_kuri_lifecycle_mutation_lock() from public, anon, authenticated;

commit;
