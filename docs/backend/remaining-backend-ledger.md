# Kuri-App — Remaining Backend Work Ledger

## Post-Hardening Master Backlog

**Created:** 27 September 2026

This ledger is the authoritative working backlog for backend work remaining from this point forward. Completed features are not to be reimplemented.

### Mandatory change workflow

1. Inspect the existing backend first — GitHub implementation plus relevant live Supabase schema/functions/RLS/triggers/migrations.
2. Classify the requested change as complete, partial, missing, GitHub-only, or GitHub + Supabase.
3. Implement the change in GitHub first. Never make a direct production Supabase change first.
4. Keep naming consistent between GitHub and Supabase: migration names/versions, tables, functions, triggers, policies, indexes and constraints.
5. Commit and push the GitHub change.
6. If a database change is required, apply the corresponding migration to Supabase.
7. Verify live Supabase and confirm GitHub/Supabase consistency.
8. Update this ledger and record any remaining verification work.
9. Stop at the checkpoint and wait before beginning the next checkpoint.

GitHub-only changes do not require a Supabase migration.

### Current remaining-work sequence

1. Admin Position Request workflow — COMPLETE
2. Kuri Announcement workflow — COMPLETE
3. Admin Security Event workflow — NEXT
4. Membership capacity/resource ceiling — NEXT
5. Remaining organization/authority work — DEFERRED
6. Expense/late-fee verification — VERIFY/HARDEN
7. Financial/state-machine verification — VERIFY/HARDEN
8. Idempotency/concurrency verification — VERIFY/HARDEN
9. Person-claim integration verification — VERIFY
10. Security/abuse hardening — VERIFY/HARDEN
11. Migration reconciliation — VERIFY/HARDEN
12. Load/performance — DEFERRED/VERIFY
13. Audit/observability — HARDEN
14. Backup/recovery — DEFERRED
15. API contract/freeze — FINAL
16. Final backend freeze — FINAL
17. Frontend/API consumers — AFTER BACKEND FREEZE

### 1. Admin Position Request Workflow — COMPLETE

Implemented and live-verified as an organization-scoped self-service Admin request workflow.

- Requester must already be an organization MEMBER.
- Request creates an organization_admin_position_requests record for the ADMIN role.
- Only existing organization ADMIN or MAIN_ADMIN users can approve/reject.
- Requester cannot approve or reject their own request.
- Approval changes the existing organization membership role MEMBER → ADMIN; it does not create a second membership.
- Rejection requires a reason.
- Requester can cancel a pending request.
- Duplicate pending requests for the same organization/requester are prevented by a partial unique index.
- Terminal states are APPROVED, REJECTED, and CANCELLED; no expiry mechanism was added because no expiration requirement exists in the current domain.
- Direct client mutation of request records is disabled; authenticated callers use dedicated SECURITY DEFINER RPCs.
- Audit records are written for create/approve/reject/cancel.
- ADMIN_POSITION_REQUEST notification production is wired on request creation, using an organization-scoped internal event emitter because the existing Kuri-scoped emitter cannot represent organization-only events.
- Existing Kuri-admin invitation/acceptance and Main Admin transfer remain separate workflows and were not modified.

GitHub migration:
supabase/migrations/20260927170917_20260927220000_admin_position_request_workflow_v1.sql

Live Supabase migration history:
version 20260927170917, name 20260927220000_admin_position_request_workflow_v1

Verification completed:
- migration present in live history
- request table, constraints, indexes and RLS verified
- authenticated-only RPC permissions verified
- anonymous execution disabled
- SECURITY DEFINER search_path=public verified
- request → notification event → dispatcher path verified transactionally
- duplicate pending request protection verified
- approval/rejection/cancellation state transitions verified transactionally
- approval role change and audit trail verified
- smoke tests rolled back, leaving no test request/notification rows

### 2. Kuri Announcement Workflow — COMPLETE

Implemented and live-verified as a Kuri-scoped administrative broadcast workflow.

- Announcement is scoped to one Kuri and records its author.
- Supported states: DRAFT → SCHEDULED → PUBLISHED → EXPIRED, with PUBLISHED/SCHEDULED → WITHDRAWN.
- Admins can create, edit, publish, schedule, and withdraw announcements through authenticated-only SECURITY DEFINER RPCs.
- Only Kuri MAIN_ADMIN/ADMIN authority can mutate announcements.
- Draft and scheduled content is editable; each content edit creates an immutable version record.
- Audience is explicitly represented as KURI_FULL_AUDIENCE: Kuri members plus the existing notification-policy administrative audiences.
- Expiry is supported and enforced by the database state processor.
- Scheduled publication and expiry are processed by a pg_cron-driven database job running every minute.
- Direct client INSERT/UPDATE/DELETE on announcements is disabled.
- Published announcement reads are restricted to actual Kuri members with linked Users or authorized Kuri/organization administrators; organization membership alone is insufficient.
- Announcement creation, editing, publication, withdrawal and state changes are audited.
- Publication produces KURI_ANNOUNCEMENT through the existing policy-driven notification architecture; actor inclusion follows the existing policy.
- No separate notification recipient system was created.

GitHub migrations:
- supabase/migrations/20260927180000_kuri_announcement_workflow_v1.sql
- supabase/migrations/20260927181000_kuri_announcement_rls_scope_hardening_v1.sql

Verification completed:
- migration history and schema verified
- announcement state machine verified transactionally
- edit/versioning verified
- scheduled publication verified
- withdrawal verified
- expiry verified
- authorization and anonymous execution restrictions verified
- RLS scope hardened and verified
- audit records verified
- KURI_ANNOUNCEMENT event creation verified
- policy-driven notification dispatch verified with a qualifying Kuri-admin recipient
- all smoke-test rows rolled back; no test announcement/event/notification/audit rows remain

### 3. Admin Security Event Workflow — NEXT

Define an explicit security-event catalog. Separate ordinary audit records from security events requiring alerts. Define event type, severity, actor, affected subject, scope, recipients, actor policy, idempotency and retention. Then connect ADMIN_SECURITY notifications. Do not turn every audit log into a notification.

### 4. Membership capacity/resource ceiling — NEXT

Existing membership_limit enforcement remains. Add a system-wide maximum membership_limit, define a safe maximum, evaluate membership × cycles × installments amplification, and harden mass-membership/resource-abuse protection.

### 5. Remaining organization/authority work — DEFERRED

Complete organization governance, explicit organization context, removal of arbitrary first-organization assumptions, organization creation/creator tracking, multiple-admin governance, Main Admin transfer, controlled recovery, organization succession/dissolution, Kuri organization transfer, and eventually granular permission/delegation.

### 6. Expense/late-fee verification — VERIFY/HARDEN

Expense and Muppu reconciliation are implemented. Verify Expense invariants, waiver/correction audit, payout/settlement edge cases and APIs. Late-fee implementation is complete; finish dedicated tests, edge cases, audit verification and API documentation.

### 7. Financial/state-machine verification — VERIFY/HARDEN

Verify payment/allocation invariants, draw/winner consistency and immutability, payout/refund integrity, exit/refund state machine, death-date cutoff, succession/current-holder behavior and historical preservation. Complete payment correction/reversal approval, append-only, reversal-limit and finalized-record tests.

### 8. Idempotency/concurrency — VERIFY/HARDEN

Audit payment, correction/reversal, draw, payout, exit/settlement and retry protection. Complete race tests for payment allocation, draw preparation, winner finalization, payout, exit/settlement and duplicate financial operations.

### 9. Person-claim integration verification — VERIFY

The secure claim workflow and dedicated test exist but have not been run in this environment. Run against a dedicated test workspace and verify cross-tenant rejection, malformed/expired token rejection, successful claim, no duplicate Person/Membership, second-claim rejection and role preservation.

### 10. Security/abuse hardening — VERIFY/HARDEN

Complete validation-matrix testing, browser session expiry/refresh testing, leaked-password protection, final JWT/Auth review, exhaustive cross-tenant identifier rejection, generic throttling/expensive-operation safeguards, suspicious/bulk-operation monitoring and abuse tests.

### 11. Migration reconciliation — VERIFY/HARDEN

Reconcile local/remote migration history and repository files without destructively rewriting production history. Document known drift, ensure future schema changes have migrations, and later assess fresh-environment reproducibility.

### 12. Load/performance — DEFERRED/VERIFY

Resolve the large-fixture/load issue; validate the 20,000-person dataset; test large installment/payment workloads, draw performance, pagination/query performance and concurrent workloads; optimize only after measurement. Review the current notifications RLS init-plan advisor finding.

### 13. Audit/observability — HARDEN

Complete financial audit coverage, administrative-action audit, winner override audit, payment correction/reversal audit, Expense waiver/correction audit, late-fee audit, exit/death/succession audit, security-event monitoring and abuse/anomaly monitoring. Keep audit logs distinct from user-facing security notifications.

### 14. Backup/recovery — DEFERRED

Define production backup strategy, recovery procedure, recovery testing and financial/audit-history preservation verification.

### 15. API contract/freeze — FINAL

Update the canonical API inventory and document authorization, membership/join, payment correction/reversal, draw/winner, Expense, exit/death/succession, late-fee, notification/event, idempotency and error contracts. Freeze the backend contract before frontend/API consumers.

### 16. Final backend freeze — FINAL

Reconcile migrations; run DB/integration tests; enable leaked-password protection; perform final JWT/Auth and RLS reviews; verify SECURITY DEFINER and anonymous execution; cross-tenant isolation; state-machine and financial invariants; Expense/settlement; death/succession; payment correction/reversal; idempotency; concurrency; input validation; abuse controls; session security; load/fixture testing; audit/observability; backup/recovery; API documentation; contract freeze.

### 17. Deferred future domains

- Tax subsystem — final scope/design still required.
- PUSH/EMAIL/SMS notification delivery — providers, device/subscription model, workers, retries/failures, credentials and preferences.
- Full organization transfer/recovery.
- Full granular permission/delegation.
- Fresh-environment reproducibility.
- Production backup/recovery implementation.
- Large-scale performance optimization.

## Completed — do not reimplement

Major completed areas include Kuri lifecycle/locking; late joining/catch-up; cycle scheduling/overrides; payment correction/reversal implementation and idempotency; draw-pool freeze; winner selection/count/no-repeat/immutability; Expense architecture and Muppu reconciliation; late-fee implementation; exit/death/succession core; invitations/join requests and abuse controls; Kuri discoverability/join policy; Person claim workflow; SECURITY DEFINER hardening; anonymous execution revocation; input/date validation; SSR session refresh; notification foundation, policy matrix, dispatcher, scheduled/domain producers and IN_APP end-to-end verification.

## Core invariants

- Organization authority ≠ Kuri authority ≠ Membership.
- Auth Account → User → Person → Membership.
- Finalized financial record → immutable.
- POOL_READY → eligibility frozen.
- Membership number continues through current holder/successor.
- Expense Rule → Expense Obligation → PAY / WAIVE / DEDUCT.
- Business Event → notification_events → recipient policy → eligible Users → deduplicate → channels.

## Ledger rule

When a new backend requirement is discovered, add it here before implementation. When an item is implemented and verified, update its status here. Conversation history is not the backlog.
