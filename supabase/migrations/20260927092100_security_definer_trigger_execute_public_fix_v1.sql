-- SEC-012/SEC-013 follow-up: PostgreSQL functions default to EXECUTE for PUBLIC.
-- Remove inherited PUBLIC execution from trigger-only functions as well.

revoke execute on function public.enforce_membership_current_holder_identity() from public, anon, authenticated;
revoke execute on function public.enforce_membership_succession_identity() from public, anon, authenticated;
revoke execute on function public.prevent_membership_succession_mutation() from public, anon, authenticated;
revoke execute on function public.enforce_cycle_historical_immutability() from public, authenticated;
revoke execute on function public.enforce_payment_append_only() from public, authenticated;
revoke execute on function public.enforce_draw_pool_eligibility_freeze() from public, authenticated;
revoke execute on function public.enforce_finalized_winner_immutability() from public, authenticated;
revoke execute on function public.enforce_draw_pool_membership_history() from public, authenticated;
revoke execute on function public.enforce_kuri_lifecycle_mutation_lock() from public, authenticated;
