# Kuri-App Backend API Surface

Status: canonical API inventory for the current Supabase production database; updated during the 2026-09-25 ledger-driven backend update.

## Exposure model

Client calls use Supabase Auth + PostgREST RPCs. Every client-facing mutation below is an authenticated application API operation. Authorization is enforced inside the function and is scoped to the target Kuri where the operation is Kuri-specific; organization context remains explicit for organization-level operations.

Security-definer is intentional for the client-facing admin RPCs because these functions centralize privileged mutations and reads behind explicit authorization and validation. Supabase's advisor flags them because they are reachable by the authenticated role; that warning is treated as a reviewed, intentional API exposure. The live reviewed authenticated SECURITY DEFINER surface is now 95 functions.

Anonymous execution is disabled for all exposed security-definer RPCs.

The three lifecycle transition RPCs are authenticated application APIs for ADMIN/MAIN_ADMIN callers. They remain protected by auth.uid(), organization/role checks, row locking, and the domain state-transition guards:
- transition_kuri_status_for_admin(uuid, kuri_status)
- transition_cycle_status_for_admin(uuid, cycle_status)
- transition_draw_status_for_admin(uuid, draw_status)

The RLS/security helpers has_org_role(uuid, app_role[]) and is_org_member(uuid) remain authenticated-callable because they are used by RLS policies.

## Canonical RPC groups

### Organization context
- list_my_organizations() -> setof record — returns organizations the signed-in user belongs to, including explicit organization type and organization-level role.
- get_organization_role(uuid) -> app_role — resolves the caller's role in an explicit organization context.
- create_organization_for_user(text, organization_type, text, text, text, text) -> uuid — creates a PERSONAL or ORGANIZATION context and makes the creator its initial MAIN_ADMIN.

### Kuri lifecycle
- close_kuri_enrollment_for_admin(uuid) -> timestamptz — explicitly closes initial enrollment while the Kuri remains `OPEN`.
- transition_kuri_status_for_admin(uuid,kuri_status) -> kuri_status — explicit lifecycle transition; `ACTIVE` records `actual_started_at`, `COMPLETED` records `completed_at`, and `ARCHIVED` records `archived_at`. Activation requires prior enrollment closure.

### Bootstrap and session
- bootstrap_kuri_admin(text) -> uuid — one-time workspace bootstrap / existing MAIN_ADMIN workspace lookup.
- get_my_workspace_id() -> uuid — current user's primary workspace.
- get_my_workspace_role() -> app_role — current user's primary workspace role.
- current_user_is_admin() -> boolean — whether the signed-in user is an ADMIN or MAIN_ADMIN.
- current_user_membership() -> table(organization_id uuid, role app_role) — current user's primary workspace membership.

### Authorization helpers
- has_org_role(uuid, app_role[]) -> boolean — RLS/security helper.
- is_org_member(uuid) -> boolean — RLS/security helper.

### Kuri and cycle management
- create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,refund_policy) -> uuid — backward-compatible single-organization creator; fails when the caller has multiple admin organizations and no explicit context is supplied.
- create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,refund_policy) -> uuid — explicit organization-scoped Kuri creation.
- get_kuri_for_admin(uuid) -> record
- list_kuris_for_admin() -> setof record
- generate_cycles_for_admin(uuid) -> integer — Kuri-scoped; terminal cycles are not rewritten and missing installments are not created for terminal cycles. — Kuri-scoped schedule generation; existing `COMPLETED`/`CANCELLED` cycle dates are not rewritten.
- generate_kuri_schedule_for_admin(uuid) -> integer — Kuri-scoped schedule generation; existing cycle rows are preserved.
- get_cycle_for_admin(uuid) -> record — Kuri-scoped cycle read.
- list_cycles_for_admin(uuid) -> setof record — Kuri-scoped cycle list.

Lifecycle state changes are exposed through the authenticated transition RPCs above; clients must not write status columns directly.

### People
- create_person_for_admin(text,text,text,text,text,text) -> uuid
- create_person_for_org_admin(uuid,text,text,text,text,text,text) -> uuid
- get_person_for_admin(uuid) -> record
- list_people_for_admin() -> setof record
- list_people_available_for_membership(uuid) -> setof record — Kuri-scoped membership picker.

### Memberships
- create_membership_for_admin(uuid,uuid,text) -> uuid — Kuri-scoped membership creation with Kuri-row capacity locking; the late-join policy creates installments only for non-terminal cycles.
- list_memberships_for_admin(uuid) -> setof record — Kuri-scoped membership read.

### Payments and installments
- create_payment_for_admin(uuid,uuid,bigint,timestamptz,payment_method,text,text,text) -> uuid — explicit Kuri scope + person membership check + required idempotency key.
- get_payment_for_admin(uuid) -> record — authorizes through the payment's Kuri.
- list_payments_for_admin(uuid) -> setof record — explicit Kuri scope.
- allocate_payment_for_admin(uuid,uuid,bigint,text) -> bigint — payment/installment must belong to the same Kuri, cannot skip an earlier outstanding installment, and uses a required idempotency key.
- allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text) -> bigint — allocates a payment strictly oldest-first across the selected membership's outstanding installments, including advance payments spanning multiple future installments, with idempotent replay protection; payment and membership installment rows are locked to serialize concurrent allocation attempts.
- list_payment_allocations_for_admin(uuid) -> setof record — scoped to the payment's Kuri.
- create_payment_correction_request_for_admin(uuid,bigint,timestamptz,payment_method,text,uuid,text,text) -> uuid — records a correction request without mutating the original payment.
- create_payment_reversal_request_for_admin(uuid,bigint,uuid,text) -> uuid — records a full or partial reversal request; partial reversal of an allocated payment targets a specific allocation.
- approve_payment_adjustment_request_for_admin(uuid) -> void — REQUESTED -> APPROVED.
- reject_payment_adjustment_request_for_admin(uuid,text) -> void — REQUESTED -> REJECTED with a required rejection reason.
- execute_payment_adjustment_request_for_admin(uuid) -> void — APPROVED -> EXECUTED; pending/rejected requests have no financial effect.
- list_payment_adjustment_requests_for_admin(uuid) -> setof record — Kuri-scoped adjustment request history.
- get_payment_adjustment_request_for_admin(uuid) -> setof record — Kuri-scoped adjustment request detail.
- list_installments_for_cycle_admin(uuid) -> setof record — cycle resolves to its Kuri authority.
- list_installments_for_payment_admin(uuid) -> setof record — explicit Kuri scope.
- list_installments_for_person_payment_admin(uuid,uuid) -> setof record — explicit Kuri + person scope.

### Draws and winners
- prepare_draw_for_admin(uuid) -> uuid — creates the draw session race-safely and freezes system eligibility when the session reaches `POOL_READY`; repeated preparation after `POOL_READY` is an idempotent read.
- set_draw_pool_entry_for_admin(uuid,boolean,text) -> void — Kuri-scoped pool override while `POOL_READY`; including a system-ineligible snapshot entry requires a reason.
- get_draw_session_for_admin(uuid) -> setof record
- list_draw_pool_for_admin(uuid) -> setof record
- run_random_draw_for_admin(uuid,integer,text) -> setof record — requires an idempotency key, consumes the frozen `POOL_READY` snapshot, and returns the stored selection set on a completed retry; later installment/member changes do not silently recalculate eligibility. The legacy 2-argument overload is removed.
- get_draw_selections_for_admin(uuid) -> setof record
- finalize_draw_for_admin(uuid,uuid[],text) -> integer — requires an idempotency key; completed retries return the existing winner count, while a reused key with a different winner payload is rejected. Final selection must come from current draw selections, must contain distinct persons, cannot repeat a prior winner in the Kuri, and is bounded by `Maximum winners = M - (C - 1)`. The legacy 2-argument overload is removed.
- get_monthly_winners_for_admin(uuid) -> setof record

### Payouts and Muppu
- prepare_payout_for_admin(uuid) -> uuid — recomputes pending payout deductions from linked `DEDUCTED_FROM_PRIZE` Expense obligations while preserving terminal payout rows.
- mark_payout_paid_for_admin(uuid,timestamptz,payment_method,text,text,text,bigint) -> void — Kuri-scoped payout payment with required idempotency key; retries of the same request replay safely, while the same key with a different payload is rejected.
- get_payout_for_admin(uuid) -> setof record — includes `expense_deductions` as a distinct payout component.
- list_payouts_for_admin(uuid) -> setof record — includes `expense_deductions` as a distinct payout component.
- audit_financial_ledger_for_admin(uuid) -> setof record — explicit Kuri scope.
- create_muppu_record_for_admin(uuid,uuid,uuid,bigint) -> uuid
- list_muppu_records_for_admin(uuid,uuid) -> setof record
- mark_muppu_paid_for_admin(uuid,text,timestamptz) -> void
- waive_muppu_for_admin(uuid,text) -> void
- deduct_muppu_from_prize_for_admin(uuid,text) -> void

### Membership exits and settlements
- create_membership_exit_for_admin(uuid,settlement_reason,date,refund_policy,bigint,text,text) -> uuid — explicit idempotency key
- approve_membership_exit_for_admin(uuid) -> void
- refresh_membership_exit_financials_for_admin(uuid) -> void
- record_membership_exit_refund_for_admin(uuid,bigint,payment_method,text,timestamptz,text,text) -> uuid — explicit idempotency key
- settle_membership_exit_for_admin(uuid,muppu_settlement_method,text,timestamptz,text) -> void — explicit idempotency key
- record_death_settlement_for_admin(uuid,uuid,text,text) -> void — explicit idempotency key
- get_membership_exit_membership_id_for_admin(uuid) -> uuid
- list_membership_exits_for_admin(uuid) -> setof record
- get_membership_exit_reconciliation_for_admin(uuid) -> setof record
- get_death_settlement_context_for_admin(uuid) -> setof record

### Nominees
- create_nominee_for_admin(uuid,text,text,text,text,text) -> uuid
- update_nominee_for_admin(uuid,text,text,text,text,text) -> void
- delete_nominee_for_admin(uuid) -> void
- list_nominees_for_admin(uuid) -> setof record
- get_membership_nominees_for_admin(uuid) -> setof record

## Authorization contract

Administrative RPCs must enforce:
1. auth.uid() is non-null.
2. Target objects resolve through their organization and, for Kuri-specific operations, Kuri boundary.
3. Caller is an ADMIN or MAIN_ADMIN of the organization for organization-level operations, or a Kuri MAIN_ADMIN/ADMIN for Kuri-scoped operations.
4. Cross-tenant identifiers are rejected.
5. State-machine rules are enforced.
6. Financial mutations lock relevant rows where concurrency could double-allocate or double-settle.
7. Draw operations enforce Kuri/cycle/draw consistency and winner-selection invariants.
8. Security-definer functions use a fixed search path.
9. Draw eligibility is frozen at `POOL_READY`; winner finalization serializes within the Kuri so no-repeat cannot be bypassed by concurrent finalizers.
10. Cycle generation and status transitions are Kuri-scoped and lock the Kuri/cycle rows; terminal (`COMPLETED`/`CANCELLED`) cycle dates are not overwritten by regeneration.

## Non-API functions

The following classes are internal database implementation and must not be exposed through the authenticated Data API:
- financial idempotency keys;
- trigger functions;
- migration/test helpers;
- audit trigger functions;
- low-level reconciliation helpers not intended as a user action.

## Verification snapshot

At the current 2026-09-25 ledger-update checkpoint:
- authenticated-callable security-definer functions: 85
- anonymous-callable security-definer functions: 0
- authenticated-callable lifecycle transition RPCs: 3
- existing Kuri records have Kuri-level MAIN_ADMIN recovery rows
- payment admin APIs are now Kuri-scoped in migration `20260925080606_payment_kuri_authority_v1`
- payment create/allocation retries are idempotent through `financial_idempotency_keys`
- draw preparation/finalization now have explicit race-safety and winner-invariant coverage; draw eligibility is snapshot-frozen at `POOL_READY`; draw execution and finalization require idempotency keys with request-hash replay protection
- payout preparation/payment now use Kuri-scoped authority, row locking, dedicated `expense_deductions` payout accounting, and `financial_idempotency_keys` for payout-payment replay protection
- cycle generation/reads/transitions now use Kuri authority, row locking, and terminal-cycle schedule immutability
- payment allocation invariant checks and a real parallel-session race test are maintained in the DB regression/integration suites

Frontend clients should call this API through the Supabase client rather than writing directly to protected domain tables.

## Generalized Expenses

The Expense layer is now distinct from legacy Muppu history and follows the canonical rule → obligation → settlement model.

- `create_expense_rule_for_admin(kuri_id,name,description,frequency,amount,active)` creates a Kuri-scoped rule. Frequencies are `ONE_TIME` and `PER_CYCLE`.
- `set_expense_rule_active_for_admin(rule_id,active)` disables or re-enables future obligation generation without deleting historical obligations.
- `list_expense_rules_for_admin(kuri_id)` and `list_expense_obligations_for_admin(kuri_id,cycle_id)` expose controlled admin reads.
- `mark_expense_obligation_paid_for_admin(obligation_id,reference,paid_at)` moves an unpaid obligation to `PAID`.
- `waive_expense_obligation_for_admin(obligation_id,reason)` moves an unpaid obligation to `WAIVED`; a reason is required.
- `deduct_expense_from_prize_for_admin(obligation_id,payout_id,reference)` moves an unpaid obligation to `DEDUCTED_FROM_PRIZE` only when the referenced payout is `PENDING`, belongs to the same Kuri, and targets the same person.

Existing completed/cancelled cycle history is not recreated for new per-cycle rules. New active memberships and schedule generation synchronize active Expense rules through internal, non-client-callable helpers. Expense tables use RLS with direct client table access revoked, and Expense mutations are included in the financial audit trail.

## Payout Expense accounting

Payout net amount is constrained as `max(gross_amount - muppu_amount - expense_deductions - other_deductions, 0)`. Generalized Expense deductions are stored separately from legacy Muppu and manually supplied other deductions. A prize Expense can be attached only while the payout is `PENDING`; payout preparation re-derives the linked Expense total from `DEDUCTED_FROM_PRIZE` obligations, preventing stale net amounts.



## Membership exit, death settlement, and succession

Exit lifecycle: `ACTIVE/SUSPENDED -> PENDING -> APPROVED -> SETTLED -> EXITED`. A `PENDING` exit does not change membership status or remove the member from ordinary operations; cancellation preserves the historical exit request. Creating an exit request does not make the membership exited; pending members remain operational. Cancellation preserves the historical exit row and allows a later request. Exit settlement recalculates financials from `calculate_membership_exit_financials`, using effective payment/allocation values and the ledger’s pre-win/post-win, Expense, Muppu and request/death cutoff rules.

Canonical mutation APIs:
- `create_membership_exit_for_admin(membership_id, reason, exit_date, refund_policy, refund_amount, notes, idempotency_key)`
- `approve_membership_exit_for_admin(exit_id)`
- `verify_death_date_for_admin(exit_id, verified_death_date, verification_notes)`
- `cancel_membership_exit_for_admin(exit_id, cancellation_reason)`
- `record_membership_exit_refund_for_admin(exit_id, refund_amount, payment_method, reference, paid_at, notes, idempotency_key)`
- `settle_membership_exit_for_admin(exit_id, settlement_method, reference, settlement_date, idempotency_key)`
- `record_death_settlement_for_admin(exit_id, nominee_id, settlement_notes, idempotency_key)`
- `create_membership_succession_for_admin(exit_id, nominee_id, succession_notes)`

Death settlement requires a verified death date and a nominee registered to the original member. Payments, draws and other post-death operations are blocked from the death settlement path once the death is verified. Succession is append-only: the original `person_id` and membership number remain unchanged; `current_holder_person_id` identifies the successor for ongoing operations.

Operational APIs use `coalesce(current_holder_person_id, person_id)` after succession, so successor payments/installments/draw identity follow the current holder while historical membership identity remains intact.
