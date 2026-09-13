# Kuri-App Technical Blueprint

**Version:** 1.0  
**Status:** Baseline architecture for implementation

## 1. Purpose

Kuri-App is a web application for managing Kerala/community-style Kuris. The architecture supports people, multiple memberships, cycle-based installments, payments and allocations, Muppu, an Admin-controlled random draw workflow, final monthly winners, payouts, exits/refunds, privacy, roles, reporting, and audit history.

The application should remain simple to operate while keeping the data model strong enough for future features such as auction mode, notifications, and multiple organizations.

## 2. Technology stack

- **Application framework:** Next.js 16 with App Router
- **Language:** TypeScript
- **UI:** React
- **Styling:** Tailwind CSS
- **Component system:** shadcn/ui
- **Database:** PostgreSQL through Supabase
- **Authentication:** Supabase Auth
- **File storage:** Supabase Storage
- **Authorization:** PostgreSQL Row-Level Security (RLS), backed by application-level permission checks
- **Validation:** Zod
- **Testing:** Vitest for unit/business-logic tests; Playwright for end-to-end tests
- **Hosting:** Vercel for Next.js; Supabase for database/auth/storage
- **Repository:** `kmusammil/Kuri-App`

No separate Express server, Python backend, MongoDB, Redis, microservices, Docker/Kubernetes, or GraphQL layer is required for v1.

## 3. Architecture

```text
Browser
  |
  v
Next.js App Router
  |
  +-- Server Components / Pages
  +-- Client Components for interactive UI
  +-- Server Actions for application mutations
  +-- Route Handlers for API/webhook-style endpoints
  |
  v
Domain / Service Layer
  |
  +-- Kuri rules
  +-- Membership logic
  +-- Installment/payment logic
  +-- Draw engine
  +-- Winner/final-selection logic
  +-- Muppu logic
  +-- Payout/settlement logic
  +-- Authorization
  +-- Audit logging
  |
  v
Supabase
  +-- PostgreSQL
  +-- Auth
  +-- Storage
  +-- RLS
```

The UI must not contain authoritative business rules. Important mutations go through domain/service functions that validate permissions and invariants before changing data.

## 4. Repository structure

```text
Kuri-App/
├── app/
│   ├── (auth)/
│   ├── (admin)/
│   ├── (member)/
│   ├── api/
│   ├── layout.tsx
│   └── globals.css
├── components/
│   ├── ui/
│   ├── admin/
│   ├── member/
│   └── shared/
├── features/
│   ├── organizations/
│   ├── users/
│   ├── people/
│   ├── kuris/
│   ├── memberships/
│   ├── cycles/
│   ├── installments/
│   ├── payments/
│   ├── muppu/
│   ├── draws/
│   ├── winners/
│   ├── payouts/
│   ├── settlements/
│   ├── reports/
│   └── audit/
├── lib/
│   ├── auth/
│   ├── db/
│   ├── permissions/
│   ├── validation/
│   ├── storage/
│   └── utils/
├── supabase/
│   ├── migrations/
│   ├── seed.sql
│   └── config.toml
├── tests/
│   ├── unit/
│   └── e2e/
├── docs/
│   ├── PRODUCT_SPEC.md
│   ├── BUSINESS_RULES.md
│   ├── DATA_MODEL.md
│   ├── PERMISSIONS.md
│   ├── DRAW_SYSTEM.md
│   └── TECHNICAL_BLUEPRINT.md
├── public/
├── package.json
├── tsconfig.json
├── next.config.ts
├── eslint.config.mjs
└── README.md
```

Exact files may be adjusted during implementation, but the separation between UI, feature/domain logic, infrastructure, database migrations, tests, and documentation should remain.

## 5. Core domain entities

- Organization
- User
- Organization User / Role
- Person
- Person Phone
- Person Email
- Kuri
- Membership
- Cycle
- Installment
- Payment
- Payment Allocation
- Muppu Record
- Draw Session
- Draw Pool Entry
- Draw Selection
- Monthly Winner
- Monthly Winner Membership
- Payout
- Membership Exit / Settlement
- Nominee
- Audit Log
- Stored File metadata

The critical separation is:

```text
Person != Membership != Installment != Payment != Draw Selection != Monthly Winner != Payout
```

## 6. Database rules

### IDs

Use UUID primary keys for application entities.

### Money

Store monetary values as integer **paise** using PostgreSQL `bigint`.

Examples:

- ₹5,000 = `500000`
- ₹1,00,000 = `10000000`

Never use floating-point values for money.

### Timestamps

Store timestamps in UTC. Render dates/times in the organization's configured timezone. India/Kerala is the initial target locale.

### History

Do not hard-delete financially significant records. Use lifecycle/status fields and preserve historical records.

### Referential integrity

Use PostgreSQL foreign keys and unique/check constraints for invariants that the database can enforce.

## 7. Main tables

### organizations

`id`, `name`, `description`, `phone`, `email`, `address`, `logo_url`, `created_at`, `updated_at`

### users

`id`, `person_id`, `email`, `phone`, `auth identity reference`, `status`, `created_at`, `last_login_at`

Authentication credentials are handled by Supabase Auth; application tables must not store plaintext passwords.

### organization_users

`id`, `organization_id`, `user_id`, `role`, `created_at`

Roles:

- `MAIN_ADMIN`
- `ADMIN`
- `MEMBER`

### people

`id`, `registered_name`, `display_name`, `address`, `photo_url`, `notes`, `created_at`, `updated_at`

### person_phones

`id`, `person_id`, `phone_number`, `label`, `is_primary`

### person_emails

`id`, `person_id`, `email`, `label`, `is_primary`

### kuris

`id`, `organization_id`, `name`, `description`, `start_date`, `number_of_cycles`, `membership_limit`, `installment_amount`, `frequency`, `due_day`, `draw_day`, `gross_prize_amount`, `muppu_amount`, `draw_eligibility_rule`, `winner_rule`, `exit_refund_rule`, `status`, `created_at`, `updated_at`

Defaults:

- `frequency = MONTHLY`
- `draw_eligibility_rule = PAID_INSTALLMENT`
- `winner_rule = ALL_PERSON_MEMBERSHIPS`
- `exit_refund_rule = AT_MATURITY`

### memberships

`id`, `kuri_id`, `person_id`, `membership_number`, `status`, `joined_at`, `exited_at`, `completed_at`, `created_at`

Statuses:

- `PENDING`
- `ACTIVE`
- `SUSPENDED`
- `EXITED`
- `COMPLETED`
- `TRANSFERRED`

Unique constraint: `(kuri_id, membership_number)`.

### cycles

`id`, `kuri_id`, `cycle_number`, `period_start`, `period_end`, `due_date`, `draw_date`, `status`, `created_at`

Unique constraint: `(kuri_id, cycle_number)`.

### installments

`id`, `membership_id`, `cycle_id`, `amount_due`, `amount_paid`, `status`, `due_date`, `created_at`, `updated_at`

Unique constraint: `(membership_id, cycle_id)`.

Statuses:

- `UNPAID`
- `PARTIAL`
- `PAID`
- `PAID_LATE`
- `ADVANCE`
- `WAIVED`

`amount_paid` should be calculated from approved payment allocations and maintained transactionally rather than manually edited by ordinary UI code.

### payments

`id`, `person_id`, `amount`, `payment_date`, `method`, `reference_number`, `proof_file_id`, `status`, `submitted_at`, `verified_at`, `verified_by`, `notes`, `created_at`

Methods initially:

- `UPI`
- `BANK_TRANSFER`
- `CASH`
- `OTHER`

Statuses:

- `PENDING_VERIFICATION`
- `APPROVED`
- `REJECTED`
- `CANCELLED`

### payment_allocations

`id`, `payment_id`, `installment_id`, `amount`, `allocated_at`, `allocated_by`

Constraint: total allocations for a payment cannot exceed the payment amount.

### muppu_records

`id`, `kuri_id`, `cycle_id`, `person_id`, `amount`, `status`, `settlement_method`, `paid_at`, `payment_reference`, `created_at`

Statuses:

- `UNPAID`
- `PAID`
- `DEDUCTED`
- `WAIVED`

Settlement methods:

- `PAID_IN_ADVANCE`
- `DEDUCTED_FROM_PRIZE`
- `WAIVED`

The exact association with membership/winner units can be refined during accounting implementation without changing the overall architecture.

### draw_sessions

`id`, `kuri_id`, `cycle_id`, `conducted_by`, `status`, `started_at`, `completed_at`, `created_at`

Statuses:

- `DRAFT`
- `POOL_READY`
- `DRAWING`
- `RESULTS_READY`
- `FINALIZED`
- `CANCELLED`

### draw_pool_entries

`id`, `draw_session_id`, `membership_id`, `system_eligible`, `admin_included`, `override`, `override_reason`, `modified_by`, `modified_at`

Unique constraint: `(draw_session_id, membership_id)`.

The system's eligibility recommendation never prevents an authorized Admin from changing the actual draw pool.

### draw_selections

`id`, `draw_session_id`, `membership_id`, `selection_order`, `selected_at`, `randomization_id`

Every random selection is historical and should not be overwritten by later Admin decisions.

### monthly_winners

`id`, `cycle_id`, `person_id`, `selection_source`, `finalized_by`, `finalized_at`, `status`, `notes`

Selection source:

- `RANDOM_DRAW`
- `ADMIN_OVERRIDE`

A cycle may have zero, one, or many monthly winners.

### monthly_winner_memberships

`id`, `monthly_winner_id`, `membership_id`, `award_amount`, `created_at`

Unique constraint: `(monthly_winner_id, membership_id)`.

### payouts

`id`, `monthly_winner_id`, `gross_amount`, `muppu_amount`, `other_deductions`, `net_amount`, `payment_date`, `method`, `reference_number`, `status`, `processed_by`, `notes`

Statuses:

- `PENDING`
- `PROCESSING`
- `PAID`
- `CANCELLED`

### membership_exits

`id`, `membership_id`, `reason`, `exit_date`, `refund_policy`, `amount_contributed`, `refund_amount`, `status`, `approved_by`, `settled_at`, `notes`

Reasons:

- `VOLUNTARY_EXIT`
- `DEATH`
- `OTHER`

Refund policy:

- `AT_MATURITY` (default)
- `IMMEDIATE`

### nominees

Optional nominee/authorized-recipient information for settlement workflows.

### audit_logs

`id`, `organization_id`, `user_id`, `action`, `entity_type`, `entity_id`, `old_data`, `new_data`, `reason`, `created_at`

Use JSONB snapshots where useful for before/after state.

### files

Metadata for uploaded payment proofs, QR codes, member photos, receipts, and reports. Actual file bytes are stored in Supabase Storage.

## 8. Draw architecture

The draw has four distinct concepts:

```text
System Eligibility
       ↓
Admin-controlled Draw Pool
       ↓
Random Draw Selections
       ↓
Admin Final Selection
       ↓
Monthly Winners
```

### System eligibility

The Kuri provides a default eligibility rule. Initially this is normally payment-based.

### Admin-controlled pool

The Admin can add or remove any membership from the actual draw pool, including overriding the system recommendation. An override should generate an audit entry.

### Random draw

The randomizer selects from the Admin-confirmed pool.

The random result has **no automatic business consequence**.

### Admin final selection

After drawing, the Admin can:

- Accept random selections
- Remove selected people
- Draw again
- Add people who were not randomly selected
- Select multiple people
- Select no one
- Finalize any appropriate set of monthly winners

Only finalized monthly winners proceed to prize/payout processing.

Therefore:

```text
Random selection != automatic winner
```

The application preserves the random result internally even if the Admin completely overrides it.

## 9. Multiple memberships

Memberships are the basic draw/accounting units, while people provide identity/grouping.

If a person has three memberships:

- They have three installment obligations.
- They have three draw entries when eligible/included.
- If the Kuri's default winner rule is `ALL_PERSON_MEMBERSHIPS`, awarding that person fulfills all of their memberships.
- A Kuri may instead configure a membership-only winner rule.

The system must not assume that one person can only have one membership.

## 10. Payment architecture

Separate:

1. Installment — what is owed.
2. Payment — what was received.
3. Allocation — which installment(s) the payment settles.

This supports late and partial payments without changing historical cycle dates.

All financial mutations that affect balances should execute inside database transactions.

## 11. Authentication and authorization

Supabase Auth manages identity/authentication.

Application authorization is based on organization membership and role.

### Main Admin

Full organizational control, including Kuri configuration, Admin management, financial operations, draw overrides, final winners, payouts, settlements, and audit history.

### Admin

Operational access based on configured permissions. The architecture should support granular permissions later rather than assuming every Admin has unrestricted access.

### Member

Access only to their own private financial and membership data plus information explicitly designated as member-visible.

Members must not access other members' payment records, screenshots, balances, notes, or settlements.

## 12. Row-Level Security

PostgreSQL RLS is a security boundary, not merely a UI feature.

Policies should ensure that:

- Organization users can only access data belonging to organizations they belong to.
- Members can only access their own authorized records.
- Admin access follows role/permission rules.
- Sensitive file objects follow the same authorization model.

Server-side service functions should still perform explicit authorization checks before privileged mutations.

## 13. Application routes

Initial route structure:

```text
/auth/login
/auth/forgot-password

/admin
/admin/kuris
/admin/kuris/[kuriId]
/admin/kuris/[kuriId]/members
/admin/kuris/[kuriId]/memberships
/admin/kuris/[kuriId]/cycles
/admin/kuris/[kuriId]/payments
/admin/kuris/[kuriId]/draws
/admin/kuris/[kuriId]/winners
/admin/kuris/[kuriId]/payouts
/admin/kuris/[kuriId]/settlements
/admin/kuris/[kuriId]/reports
/admin/audit
/admin/settings

/member
/member/kuris
/member/kuris/[kuriId]
/member/payments
/member/receipts
/member/draw-history
/member/profile
```

Routes may evolve during UX implementation; authorization remains independent of route naming.

## 14. Server-side domain modules

Conceptual operations include:

```text
createKuri()
updateKuriRules()
createMembership()
createCycle()
generateInstallments()
submitPayment()
approvePayment()
allocatePayment()
createDrawSession()
updateDrawPool()
runRandomDraw()
finalizeMonthlyWinners()
createPayout()
recordSettlement()
```

Exact signatures will be defined during implementation.

## 15. Transactions and concurrency

Use PostgreSQL transactions for operations that modify related financial or draw records together.

Examples:

- Approving a payment + allocations + balance updates
- Finalizing winners + membership consequences + audit records
- Recording a payout + Muppu settlement
- Closing a cycle

Draw finalization should prevent two Admin sessions from independently finalizing conflicting results for the same cycle.

## 16. Random draw integrity

The draw engine should use a cryptographically strong server-side random source rather than client-side `Math.random()` for authoritative selection.

The UI animation is cosmetic and must never determine the result. The authoritative random selection is generated server-side.

## 17. File handling

Use Supabase Storage for:

- Payment screenshots
- UPI QR images
- Member photos
- Receipts
- Generated reports

Files should be private by default when they contain personal/financial information. Access should use authenticated/authorized application flows.

## 18. Validation

Use Zod schemas at application boundaries for:

- Kuri configuration
- Person/member forms
- Payment submissions
- Draw operations
- Winner finalization
- Payouts
- Settlement actions

Database constraints remain the final integrity layer.

## 19. Error handling

Categorize errors as:

- Validation errors
- Authorization errors
- Not-found errors
- Business-rule conflicts
- Database/infrastructure errors

The UI should show useful, non-technical messages while logs preserve technical details. Never expose database internals, secrets, or stack traces to members.

## 20. Testing strategy

### Unit tests — Vitest

Prioritize business rules:

- Multiple membership calculations
- Installment generation
- Partial payment allocation
- Late payment handling
- Muppu calculations
- Draw eligibility defaults
- Admin eligibility overrides
- Random selection behavior
- Final winner override behavior
- Multiple winners
- All-memberships winner rule
- Membership-only winner rule
- Exit/refund rules

### End-to-end tests — Playwright

Critical workflows:

1. Main Admin creates a Kuri.
2. Admin adds a person with multiple memberships.
3. Installments are generated.
4. Member submits payment proof.
5. Admin verifies payment.
6. Admin opens a draw and changes the pool.
7. Random draw is conducted.
8. Admin changes the result and finalizes winners.
9. Payout is recorded.
10. Member sees only permitted information.
11. Exit and settlement workflow is completed.

## 21. Reporting architecture

Reports should query authoritative records rather than maintain manually edited totals.

Initial reports:

- Collection summary
- Outstanding/arrears
- Member ledger
- Membership ledger
- Payment history
- Draw history
- Winner history
- Muppu report
- Payout report
- Exit/settlement report
- Kuri summary

PDF/Excel generation can be added after core workflows are stable.

## 22. Notifications architecture

Notification delivery should be abstracted behind a service interface so channels can be added without changing core business logic.

Potential channels:

- In-app
- Email
- WhatsApp Business/API
- SMS

Notifications are not required for the core accounting/draw engine.

## 23. Localization

Design the UI and data model for:

- English
- Malayalam

Indian localization should include:

- INR formatting
- Indian phone numbers
- UPI
- Kerala-oriented terminology

Strings should not be hard-coded throughout components so additional languages can be added later.

## 24. Development phases

### Phase 0 — Foundation

- Next.js/TypeScript project
- Supabase project connection
- Database migrations
- Auth
- Base layout/navigation
- RLS foundation
- Seed/test data
- CI/test setup

### Phase 1 — Kuri and people

- Organizations
- Kuri creation/configuration
- People
- Memberships
- Multiple memberships
- Kuri lifecycle

### Phase 2 — Cycles and payments

- Cycle generation
- Installments
- Payment submission
- Verification
- Allocation
- Outstanding/late/partial states
- Muppu

### Phase 3 — Draw

- Eligibility calculation
- Admin draw pool
- Eligibility overrides
- Random draw
- Multiple selections
- Draw history
- Admin override
- Final monthly winners
- Winner membership consequences

### Phase 4 — Payout and settlement

- Payouts
- Muppu settlement
- Exit
- Refund
- Death settlement

### Phase 5 — Reporting and member experience

- Admin dashboard
- Member dashboard
- Receipts
- Reports
- Audit viewer

### Phase 6 — Optional integrations

- UPI QR management
- Email notifications
- WhatsApp integration
- Other notification channels
- Advanced exports

## 25. Explicit non-goals for v1

Do not introduce these unless later product decisions require them:

- Separate microservices
- Complex accounting/ERP
- Payment gateway integration
- Auction/bidding engine
- Banking integrations
- Full KYC/compliance platform
- Enterprise multi-tenant complexity beyond the organization model
- Real-time infrastructure unless a feature actually needs it

## 26. Architectural principles

1. **Business rules live in the domain layer, not UI components.**
2. **The database is authoritative for financial state.**
3. **Random draw results and final Admin selections are separate.**
4. **Admin overrides are allowed but auditable.**
5. **Historical financial/draw records are never silently deleted.**
6. **Membership is the unit of participation; Person is the identity/grouping unit.**
7. **Installments, payments, and allocations remain separate.**
8. **Members see only data they are authorized to see.**
9. **Money is represented in integer paise.**
10. **The initial architecture stays simple while leaving clean extension points for future features.**

## 27. Implementation gate

Before implementing production features, the following documents should agree with this blueprint:

- `PRODUCT_SPEC.md`
- `BUSINESS_RULES.md`
- `DATA_MODEL.md`
- `PERMISSIONS.md`
- `DRAW_SYSTEM.md`

If a later feature conflicts with these rules, update the relevant specification first, then implement the change.
