begin;

-- Membership Exit hardening follow-up.
-- 1. Keep lifecycle trigger helpers internal: they are trigger entrypoints,
--    not API RPCs.
-- 2. Keep the refund ledger closed to direct API writes.
-- 3. Keep the lifecycle transition RPCs as the only public status API.

-- Close the entire SECURITY DEFINER surface to anonymous callers. Individual
-- client-facing RPCs are explicitly re-granted to authenticated users by the
-- canonical migrations that own them.
revoke execute on all functions in schema public from anon;

-- These helpers are trigger/internal entrypoints, not client-facing RPCs.
revoke execute on function public.enforce_kuri_status_transition() from authenticated;
revoke execute on function public.enforce_cycle_status_transition() from authenticated;
revoke execute on function public.enforce_draw_status_transition() from authenticated;
revoke execute on function public.enforce_payout_status_transition() from authenticated;
revoke execute on function public.enforce_membership_status_transition() from authenticated;
revoke execute on function public.enforce_membership_exit_status_transition() from authenticated;
revoke execute on function public.enforce_draw_domain_integrity() from authenticated;
revoke execute on function public.enforce_payout_cycle_completion() from authenticated;

-- These tables are intentionally RPC-managed. RLS stays enabled and no
-- authenticated/anon table DML privileges are granted.
-- Direct table mutations are RPC-managed. Preserve existing SELECT grants/policies.
revoke insert, update, delete on all tables in schema public from anon, authenticated;

revoke all on table public.membership_exits from anon, authenticated;
revoke all on table public.membership_exit_refund_transactions from anon, authenticated;

commit;
