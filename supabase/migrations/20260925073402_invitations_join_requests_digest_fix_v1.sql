-- Remote migration-history reconciliation.
-- The invitation digest implementation is already present in the preceding
-- 20260925073310_invitations_join_requests_digest_fix_v1 migration on this branch.
-- Keep this version as a no-op so local migration history can represent the
-- production migration ledger without replaying the same schema operation.

begin;
commit;