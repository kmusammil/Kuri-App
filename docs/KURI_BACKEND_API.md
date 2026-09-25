# Kuri-App Backend API Surface

Status: canonical API inventory for the current Supabase production database; updated during the 2026-09-25 ledger-driven backend update.

## Exposure model

Client calls use Supabase Auth + PostgREST RPCs. Every client-facing mutation below is an authenticated application API operation. Authorization is enforced inside the function and is scoped to the target Kuri where the operation is Kuri-specific; organization context remains explicit for organization-level operations.

Security-definer is intentional for the client-facing admin RPCs because these functions centralize privileged mutations and reads behind explicit authorization and validation. Supabase's advisor flags them because they are reachable by the authenticated role; that warning is treated as a reviewed, intentional API exposure. The live reviewed authenticated SECURITY DEFINER surface is now 77 functions.

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
- generate_cycles_for_admin(uuid) -> integer
- generate_kuri_schedule_for_admin(uuid) -> integer
- get_cycle_for_admin(uuid) -> record
- list_cycles_for_admin(uuid) -> setof record

Lifecycle state changes are exposed through the authenticated transition RPCs above; clients must not write status columns directly.

### People
- create_person_for_admin(text,text,text,text,text,text) -> uuid
- create_person_for_org_admin(uuid,text,text,text,text,text,text) -> uuid
- get_person_for_admin(uuid) -> record
- list_people_for_admin() -> setof record
- list_people_available_for_membership(uuid) -> setof record

### Memberships
- create_membership_for_admin(uuid,uuid,text) -> uuid
- list_memberships_for_admin(uuid) -> setof record

### Payments and installments
- create_payment_for_admin(uuid,uuid,bigint,timestamptz,payment_method,text,text,text) -> uuid — explicit Kuri scope + person membership check + required idempotency key.
- get_payment_for_admin(uuid) -> record — authorizes through the payment's Kuri.
- list_payments_for_admin(uuid) -> setof record — explicit Kuri scope.
- allocate_payment_for_admin(uuid,uuid,bigint,text) -> bigint — payment and installment must belong to the same Kuri + required idempotency key.
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
- prepare_draw_for_admin(uuid) -> uuid
- set_draw_pool_entry_for_admin(uuid,boolean,text) -> void
- get_draw_session_for_admin(uuid) -> setof record
- list_draw_pool_for_admin(uuid) -> setof record
- run_random_draw_for_admin(uuid,integer) -> setof record
- get_draw_selections_for_admin(uuid) -> setof record
- finalize_draw_for_admin(uuid,uuid[]) -> integer
- get_monthly_winners_for_admin(uuid) -> setof record

### Payouts and Muppu
- prepare_payout_for_admin(uuid) -> uuid
- mark_payout_paid_for_admin(uuid,timestamptz,payment_method,text,text,bigint) -> void
- get_payout_for_admin(uuid) -> setof record
- list_payouts_for_admin(uuid) -> setof record
- audit_financial_ledger_for_admin(uuid) -> setof record — explicit Kuri scope.
- create_muppu_record_for_admin(uuid,uuid,uuid,bigint) -> uuid
- list_muppu_records_for_admin(uuid,uuid) -> setof record
- mark_muppu_paid_for_admin(uuid,text,timestamptz) -> void
- waive_muppu_for_admin(uuid,text) -> void
- deduct_muppu_from_prize_for_admin(uuid,text) -> void

### Membership exits and settlements
- create_membership_exit_for_admin(uuid,settlement_reason,date,refund_policy,bigint,text) -> uuid
- approve_membership_exit_for_admin(uuid) -> void
- refresh_membership_exit_financials_for_admin(uuid) -> void
- record_membership_exit_refund_for_admin(uuid,bigint,payment_method,timestamptz,text) -> uuid
- settle_membership_exit_for_admin(uuid,muppu_settlement_method,text,timestamptz) -> void
- record_death_settlement_for_admin(uuid,uuid,text) -> void
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

## Non-API functions

The following classes are internal database implementation and must not be exposed through the authenticated Data API:
- financial idempotency keys;
- trigger functions;
- migration/test helpers;
- audit trigger functions;
- low-level reconciliation helpers not intended as a user action.

## Verification snapshot

At the current 2026-09-25 ledger-update checkpoint:
- authenticated-callable security-definer functions: 84
- anonymous-callable security-definer functions: 0
- authenticated-callable lifecycle transition RPCs: 3
- existing Kuri records have Kuri-level MAIN_ADMIN recovery rows
- payment admin APIs are now Kuri-scoped in migration `20260925080606_payment_kuri_authority_v1`
- payment create/allocation retries are idempotent through `financial_idempotency_keys`

Frontend clients should call this API through the Supabase client rather than writing directly to protected domain tables.
