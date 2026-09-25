# Kuri-App Backend Completion

Date: 2026-09-25

## Status

**Previous backend freeze (2026-09-22) is superseded by the Master Backend Improvement Ledger. Ledger-driven backend update is in progress.**

The database/API layer is now considered the backend contract for the application. New backend work should only be opened when frontend integration exposes a concrete defect or a genuinely new product requirement.

## Completed

- Multi-tenant organization boundaries and authorization.
- RLS on all 31 public tables.
- Authenticated PostgREST RPC/API surface with anonymous RPC exposure removed.
- SECURITY DEFINER functions reviewed and hardened with fixed search paths.
- Kuri, cycle, draw, membership, exit, payout, and settlement state machines.
- Draw eligibility snapshot freeze, winner no-repeat/max-feasible-count invariants, and membership invariants.
- Payout Kuri-scoped authority, payout row-locking, and payout-payment idempotency/replay protection.
- Cycle Kuri-scoped authority, cycle row locking, and terminal-cycle schedule immutability.
- Draw and payout concurrency protection.
- Payment and installment allocation integrity currently has clean live data; payment creation/allocation now have authenticated idempotency/replay protection; payment correction/reversal is append-only and approval-gated; allocation now enforces no-skipping and supports deterministic oldest-first advance-payment allocation; allocation financial invariants and authenticated concurrent-race coverage are now maintained in the regression/integration test suites.
- Payout and Muppu accounting invariants.
- Membership exit/refund/death-settlement flows.
- Nominee tenancy and access controls.
- Person/contact tenancy isolation.
- Financial audit trail.
- Domain identity immutability.
- Cross-domain tenant and financial integrity checks.
- Authenticated API contract suite is maintained alongside the live API surface; the branch test plans are updated for the current 2026-09-25 API surface.
- Positive authenticated workflow and concurrency coverage completed.
- Disposable positive E2E fixtures cleaned from the test organization.
- Canonical backend API documentation.
- Explicit organization type/context foundation.
- Kuri-scoped MAIN_ADMIN/ADMIN authority foundation.
- Payment-operation idempotency for payment creation and allocation, with request-hash replay protection.
- Payment correction/reversal requests with REQUESTED -> APPROVED -> EXECUTED or REQUESTED -> REJECTED, append-only financial entries, required reasons, and audit events.
- Invitation and join-request workflow with single-use codes, expiry/revocation, explicit approval/rejection, and audit events.

## Final live verification

- Public tables: 31
- Public tables with RLS: 31
- Authenticated SECURITY DEFINER application APIs: 85, intentionally exposed
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

Migration `20260925072540_identity_organization_authority_v1` was applied to the production project and establishes explicit organization type/context plus Kuri-scoped admin authority. Existing Kuris then received an audited legacy MAIN_ADMIN recovery via `kuri_admin_legacy_recovery_v1`; no historical creator was invented. Payment APIs were subsequently moved from organization-wide authorization to explicit Kuri scope in `20260925080606_payment_kuri_authority_v1`. Payment correction/reversal is implemented in `20260925082608_payment_correction_reversal_v1`; allocation policy is implemented in `20260925083209` + `20260925083456`. The payment allocation-policy slice is complete; its financial invariants are checked against live data, and a true parallel authenticated allocation race is maintained in the integration suite.


## 2026-09-25 draw hardening update

The live draw surface now uses Kuri-scoped authority for draw state, preparation, pool overrides, random draw, and winner finalization. Draw preparation is idempotent after `POOL_READY`, so the eligibility snapshot cannot be silently recomputed. Random draw execution consumes the frozen `system_eligible` snapshot. Winner finalization serializes on the Kuri row and enforces distinct-person winners, no-repeat winners within the Kuri, and the ledger formula `Maximum winners = M - (C - 1)`. Regression and authenticated integration coverage has been added for these invariants and for concurrent draw preparation/finalization.


## 2026-09-25 payout hardening update

The payout surface now uses Kuri-scoped authority for preparation, status transitions, reads, and payout payment processing. `mark_payout_paid_for_admin` requires an idempotency key and binds the complete payout request to `financial_idempotency_keys`; a completed retry is a no-op and a reused key with a different payload is rejected. The integration suite includes authenticated concurrent payout preparation and same-key payment replay coverage.


## 2026-09-25 cycle authority update

Cycle generation, schedule generation, cycle reads, and cycle status transitions now authorize through Kuri administration. Cycle/Kuri rows are locked during mutation, and schedule regeneration will not rewrite dates on `COMPLETED` or `CANCELLED` cycles. Live rollback checks confirmed cross-Kuri access is rejected, terminal cycle dates survive regeneration, and no idempotency residue is left behind.


## 2026-09-25 membership/enrollment hardening update

Membership creation, membership reads, membership status transitions, and the membership picker now authorize through Kuri administration. Membership creation continues to lock the Kuri row for capacity enforcement. The implementation adopts the ledger-required non-retroactive late-join policy because the source ledger does not define a separate catch-up vocabulary: new memberships receive installments only for non-terminal cycles, while `COMPLETED` and `CANCELLED` cycle history is not recreated. Schedule generation follows the same rule. Live rollback verification confirmed no terminal-cycle installment creation and no test residue.


## 2026-09-25 Kuri lifecycle update

The Kuri lifecycle now records the distinction between planned and actual lifecycle events. `start_date` remains the planned date; `actual_started_at`, `enrollment_closed_at`, `completed_at`, and `archived_at` record explicit operational events. A dedicated authenticated enrollment-close API is available while the Kuri is `OPEN`, and transition to `ACTIVE` requires that closure. Existing Kuri history was not backfilled with invented timestamps.

## 2026-09-25 draw idempotency update

Draw execution and winner finalization now require idempotency keys and request-hash binding. A completed retry returns the previously stored result instead of rerunning randomness or inserting another winner; reusing the same key with a different request payload is rejected. The live transactional verification covered draw execution replay, selection-count payload mismatch, winner finalization replay, winner-set payload mismatch, and rollback cleanup.

During that verification two live defects were found and corrected: an actor-user variable/column name collision in the draw idempotency SQL, and an incomplete financial idempotency result constraint that did not yet admit DRAW_RUN, DRAW_FINALIZE, or PAYOUT_PAYMENT completion shapes. The corresponding repairs are now recorded in Git and applied in production.

## 2026-09-25 generalized Expense foundation

A generalized Expense subsystem is now live as an additive financial layer: Kuri-scoped Expense Rules generate immutable per-member obligations, with `ONE_TIME` and `PER_CYCLE` frequencies and `UNPAID → PAID / WAIVED / DEDUCTED_FROM_PRIZE` settlement states. Completed/cancelled cycle history is excluded from new per-cycle obligations. Active membership creation, membership activation, and schedule generation synchronize active rules through internal helpers.

The rollback-only live verification passed one-time and per-cycle obligation fan-out, terminal-cycle exclusion, paid/waived transitions, repeat-settlement rejection, rule deactivation/reactivation without duplication, cross-Kuri identity rejection, paid-payout deduction rejection, and audit coverage. The transaction was rolled back with zero Expense residue. Historical Muppu data remains untouched pending the later payout reconciliation migration.
