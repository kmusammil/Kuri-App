begin;

-- Membership Exit hardening follow-up.
-- 1. Keep lifecycle trigger helpers internal: they are trigger entrypoints,
--    not API RPCs.
-- 2. Keep the refund ledger closed to direct API writes.
-- 3. Keep the lifecycle transition RPCs as the only public status API.

revoke all on function public.enforce_membership_exit_status_transition() from public;
revoke all on function public.enforce_membership_status_transition() from public;

-- These tables are intentionally RPC-managed. RLS stays enabled and no
-- authenticated/anon table DML privileges are granted.
revoke all on table public.membership_exits from anon, authenticated;
revoke all on table public.membership_exit_refund_transactions from anon, authenticated;

commit;
