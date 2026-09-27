# Kuri-App Notification Matrix v1

Canonical recipient/timing specification for the current notification event catalog.

## Rules

- Recipients are resolved to **Users**, not People.
- Roles/relationships are additive; a User may be MAIN_ADMIN, ADMIN, MEMBER, CURRENT_HOLDER, WINNER, etc. simultaneously.
- Recipient resolution is deduplicated by User ID.
- Actor exclusion is event-specific; the actor is not universally suppressed.
- A Person without a linked User does not receive ordinary in-app notifications. Where the event permits it, the no-user path is invitation/claim.
- Scope is enforced: organization, Kuri, membership, cycle, payout, or the event-specific relationship.
- Reminder offsets are preferred opportunities, not guaranteed lead times. Never send a stale reminder after its target event has happened.
- Delivery channel is separate from recipient eligibility. IN_APP is the current implemented channel; PUSH/EMAIL/SMS remain supported by the data model for future delivery workers.

## Event matrix

| Event | Category | Timing | Recipients | Actor | No User | Producer status |
|---|---|---|---|---|---|---|
| KURI_START_REMINDER | REMINDER | 1 day before start | Main Admin org; Admin Kuri; Kuri members | Include | Invitation/claim | Policy only; scheduler producer not yet wired |
| KURI_END_DATE_REMINDER | REMINDER | 7 and 1 days before end | Main Admin org; Admin Kuri; Kuri members | Include | Invitation/claim | Policy only; scheduler producer not yet wired |
| ENROLLMENT_REMINDER | REMINDER | 3 days before enrollment close | Main Admin org; Admin Kuri | Include | No app notification | Policy only; scheduler producer not yet wired |
| CYCLE_REMINDER | REMINDER | 1 day before cycle | Main Admin org; Admin Kuri; Kuri members | Include | Invitation/claim | Policy only; scheduler producer not yet wired |
| PAYMENT_REMINDER | REMINDER | 3 days before and due date | Member with outstanding installment | Include | No app notification | Policy only; scheduler producer not yet wired |
| LATE_PAYMENT_ALERT | FINANCIAL | 1 day after due date if still unpaid | Main Admin org; Admin Kuri; affected member | Include | No app notification | Policy defined; late-payment producer not yet wired |
| LATE_FEE_ACTIVATED | FINANCIAL | Immediate | Main Admin org; Admin Kuri | Include | No app notification | Domain producer wired |
| LATE_FEE_CHANGED | FINANCIAL | Immediate | Main Admin org; Admin Kuri | Include | No app notification | Domain producer wired |
| DRAW_PREPARATION | REMINDER | Preferred 1 day before draw | Main Admin org; Admin Kuri; Kuri members | Include | No app notification | Domain producer wired on DRAW_PENDING; scheduled timing not yet wired |
| DRAW_RESULT | RESULT | Immediate after finalization | Main Admin org; Admin Kuri; Kuri members | Include | Invitation/claim | Domain producer wired |
| WINNER_NOTIFICATION | RESULT | Immediate after finalization | Winner; Main Admin org; Admin Kuri | Include | Invitation/claim | Domain producer wired |
| PAYOUT_NOTIFICATION | FINANCIAL | Immediate on payout status change | Winner; Main Admin org; Admin Kuri | Include | No app notification | Domain producer wired |
| EXIT_REQUEST | REQUEST | Immediate | Main Admin org; Admin Kuri; current holder | Event-specific | Invitation/claim | Domain producer wired |
| EXIT_APPROVAL | REQUEST | Immediate | Main Admin org; Admin Kuri; current holder | Event-specific | Invitation/claim | Domain producer wired |
| EXIT_SETTLEMENT | FINANCIAL | Immediate | Main Admin org; Admin Kuri; current holder | Event-specific | Invitation/claim | Domain producer wired |
| DEATH_REPORT | REQUEST | Immediate | Main Admin org; Admin Kuri; current holder | Event-specific | Invitation/claim | Policy only; producer not yet wired |
| DEATH_VERIFICATION | REQUEST | Immediate | Main Admin org; Admin Kuri; current holder | Event-specific | Invitation/claim | Domain producer wired |
| SUCCESSION | REQUEST | Immediate | Main Admin org; Admin Kuri; current holder; successor | Event-specific | Invitation/claim | Domain producer wired |
| ADMIN_POSITION_REQUEST | REQUEST | Immediate | Main Admin org; Admin org | Exclude requester | No app notification | Policy only; producer not yet wired |
| JOIN_REQUEST | REQUEST | Immediate | Main Admin org; Admin Kuri | Exclude requester | Invitation/claim | Policy only; producer not yet wired |
| INVITATION_RESPONSE | REQUEST | Immediate | Main Admin org; Admin Kuri | Event-specific | No app notification | Policy only; producer not yet wired |
| KURI_SCHEDULE_CHANGED | LIFECYCLE | Immediate | Main Admin org; Admin Kuri; Kuri members | Exclude actor | Invitation/claim | Policy only; producer not yet wired |
| KURI_ANNOUNCEMENT | BROADCAST | Immediate/broadcast | Kuri members; Main Admin org; Admin Kuri | Include | Invitation/claim | Policy only; producer not yet wired |
| ADMIN_SECURITY | SECURITY | Immediate | Main Admin org; Admin org, event-specific filtering | Event-specific | No app notification | Policy only; producer not yet wired |

## Current implementation boundary

The policy registry defines the intended audience and timing semantics. The existing dispatcher still contains hard-coded recipient logic and must not be considered compliant with this matrix until it consumes the policy registry.

The next implementation checkpoint is to replace that hard-coded recipient selection with policy-driven, scope-aware, User-deduplicated resolution. Scheduled reminder generation and currently missing event producers are separate checkpoints and should not be silently folded into that change.
