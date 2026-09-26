-- Retire the legacy organization-scoped Kuri creation RPC.
-- Current Kuri creation is canonicalized through create_kuri_for_admin,
-- which creates the Kuri and its Expense Rule together.
-- No current application caller depends on this legacy RPC, and existing
-- Kuri rows have already been reconciled so muppu_amount is zero.

begin;

drop function if exists public.create_kuri_for_organization_admin(
  uuid,
  text,
  text,
  date,
  integer,
  integer,
  bigint,
  integer,
  integer,
  bigint,
  bigint,
  text,
  public.refund_policy
);

commit;
