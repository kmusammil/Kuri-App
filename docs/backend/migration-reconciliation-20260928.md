# Kuri-App — Supabase Migration Reconciliation — 28 September 2026

## Result

The production Supabase project tryyfzcbznfwlyhesryt already contains the backend domains identified as main-only during GitHub branch reconciliation. They were applied to Supabase earlier under migration-history versions that do not exactly match the GitHub source filenames.

**No production migration was applied during this checkpoint.**

## Important distinction

Supabase migration history records entries such as:

- version 20260927050550, name 20260927090000_notification_event_foundation_v1
- version 20260927051335, name 20260927092000_security_definer_trigger_execute_hardening_v1
- version 20260927053046, name abuse_004_invitation_type_hardening_v1
- version 20260927060059, name person_claim_workflow_v1
- version 20260927142414, name notification_domain_producers_v1
- version 20260927142757, name notification_scheduled_producer_v1
- version 20260927170917, name 20260927220000_admin_position_request_workflow_v1
- version 20260927171502, name 20260927180000_kuri_announcement_workflow_v1
- version 20260927171612, name 20260927181000_kuri_announcement_rls_scope_hardening_v1
- version 20260927172113, name 20260927190000_admin_security_event_workflow_v1

Therefore migration filename equality between GitHub and live history cannot be used as the sole test of whether a feature is live.

## Live verification

1. calculate_membership_exit_financials(uuid) uses verified death_date as the death settlement cutoff.
2. Person Claim functions exist: create_person_claim_token_for_admin(uuid, integer) and claim_existing_person(text).
3. Scheduled notification producer exists: generate_scheduled_notification_events(date).
4. Admin Position Request RPCs exist.
5. Kuri Announcement RPCs exist.
6. Admin Security Event notification production exists.
7. All non-internal public trigger functions were checked for execution privileges. authenticated and anon cannot execute any of them.

## GitHub reconciliation migrations

The integration branch contains grouped reconciliation migrations for source-control completeness:

- 20260928111000_security_invitation_reconciliation_v1.sql
- 20260928112000_person_payment_global_security_reconciliation_v1.sql
- 20260928113000_person_claim_notifications_reconciliation_v1.sql
- 20260928140000_admin_security_workflows_reconciliation_v1.sql

These have not been applied to production because their functionality is already present in live Supabase. They are retained as the branch's forward schema representation and must be tested against a fresh/reconciled environment before any production application.

## Current production advisory state

- RLS-enabled/no-policy findings exist for intentionally internal tables. These are informational in the current design and should not be converted into client policies merely to silence the advisor.
- The security advisor reports many authenticated-callable SECURITY DEFINER functions. These include legitimate application RPCs and therefore require function-by-function classification rather than blanket revocation.
- Trigger-only SECURITY DEFINER functions are already hardened: the direct privilege query showed authenticated_execute=false and anon_execute=false for every non-internal trigger function.
- Performance advisor reports one known RLS init-plan issue on notifications.notifications_select_own and numerous unused/uncov­ered-index findings. These belong in the later performance/observability checkpoint, not in migration-history reconciliation.

## Next checkpoint

Before frontend freeze, run the database verification suite against the reconciled backend, then perform the remaining Auth/JWT/RLS, cross-tenant, financial state-machine, idempotency/concurrency, load, and API-contract checks.