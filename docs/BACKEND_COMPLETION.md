# Kuri-App Backend Completion

Date: 2026-09-25

## Status

**Previous backend freeze (2026-09-22) is superseded by the Master Backend Improvement Ledger. Ledger-driven backend update is in progress.**

The database/API layer is now considered the backend contract for the application. New backend work should only be opened when frontend integration exposes a concrete defect or a genuinely new product requirement.

## Completed

- Multi-tenant organization boundaries and authorization.
- RLS on all 28 public tables.
- Authenticated PostgREST RPC/API surface with anonymous RPC exposure removed.
- SECURITY DEFINER functions reviewed and hardened with fixed search paths.
- Kuri, cycle, draw, membership, exit, payout, and settlement state machines.
- Draw eligibility, winner, and membership invariants.
- Draw and payout concurrency protection.
- Payment and installment allocation integrity currently has clean live data; payment creation/allocation now have authenticated idempotency/replay protection. Oldest-first/no-skipping, advance-payment handling, and correction/reversal remain ledger work.
- Payout and Muppu accounting invariants.
- Membership exit/refund/death-settlement flows.
- Nominee tenancy and access controls.
- Person/contact tenancy isolation.
- Financial audit trail.
- Domain identity immutability.
- Cross-domain tenant and financial integrity checks.
- Authenticated API contract suite is maintained alongside the live API surface; current branch plan is 33 tests.
- Positive authenticated workflow and concurrency coverage completed.
- Disposable positive E2E fixtures cleaned from the test organization.
- Canonical backend API documentation.
- Explicit organization type/context foundation.
- Kuri-scoped MAIN_ADMIN/ADMIN authority foundation.
- Payment-operation idempotency for payment creation and allocation, with request-hash replay protection.
- Invitation and join-request workflow with single-use codes, expiry/revocation, explicit approval/rejection, and audit events.

## Final live verification

- Public tables: 28
- Public tables with RLS: 28
- Authenticated SECURITY DEFINER application APIs: 77, intentionally exposed
- Anonymous SECURITY DEFINER APIs: 0
- SECURITY DEFINER functions without fixed search_path: 0
- Authenticated lifecycle transition RPCs: 3
- Remaining Integration E2E fixtures: 0
- Known historical incomplete-cycle payouts: 2

The two incomplete-cycle payout records are historical records from `kuri5`. Current payout guards prevent creation/update of payouts against incomplete cycles. They are preserved rather than rewritten because changing historical financial records would be destructive.

## Migration history

The production Supabase migration ledger remains the historical authority. Some old migration source files were superseded, consolidated, or renamed after being applied remotely. This is documented in `docs/SUPABASE_MIGRATION_HISTORY.md`.

This migration-history drift is repository reproducibility debt, not an application-runtime defect, and it is not a reason to delay frontend development or rewrite production migration history.

## Deliberately not treated as backend blockers

- Unused-index advisor notices are informational and should not be removed blindly before real production workload exists.
- The Supabase Auth leaked-password-protection warning is an Auth platform configuration setting rather than database/API implementation. The available Supabase connector does not expose that setting for programmatic modification.
- Load testing is not required to declare the backend contract complete for the current development stage. A deterministic local fixture loader is present for reproducibility testing; its runtime validation remains a local development check.

## Frontend contract

Frontend clients should use the documented authenticated RPC/API surface and Supabase Auth. They should not write directly to protected financial, draw, winner, payout, or state-machine tables.

The same backend can serve the web, Android, iOS, and desktop clients.

**Backend is not frozen. The 2026-09-22 freeze record is superseded by the active ledger-driven update.**

## 2026-09-25 update checkpoint

Migration `20260925072540_identity_organization_authority_v1` was applied to the production project and establishes explicit organization type/context plus Kuri-scoped admin authority. Existing Kuris then received an audited legacy MAIN_ADMIN recovery via `kuri_admin_legacy_recovery_v1`; no historical creator was invented. Payment APIs were subsequently moved from organization-wide authorization to explicit Kuri scope in `20260925080606_payment_kuri_authority_v1`. Payment idempotency/correction/reversal and allocation policy hardening remain pending ledger work.
