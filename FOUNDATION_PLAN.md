# Kuri-App Foundation Implementation

This file records the foundation implementation target for the current repository.

## Stack

- Next.js (App Router)
- React + TypeScript
- Tailwind CSS
- Supabase PostgreSQL
- Supabase Auth
- Supabase Storage
- PostgreSQL Row-Level Security (RLS)
- Zod
- Vitest + Playwright

## Foundation scope

1. Application shell that remains browser-visible.
2. Supabase client/server integration points.
3. Database migration layout for the Kuri-App domain model.
4. Authentication and role model: Main Admin, Admin, Member.
5. RLS policy structure for organization and member privacy.
6. Environment-variable template with no secrets.
7. Validation/domain module layout.
8. Test structure.

## Important implementation rules

- Financial history is not hard-deleted.
- Money is stored as integer paise (`bigint`).
- Person, Membership, Installment, Payment, Draw Selection, Monthly Winner, and Payout remain separate concepts.
- Draw eligibility, the Admin-controlled draw pool, random draw selections, and final monthly winners remain separate records/stages.
- Admin overrides are permitted and auditable.
- Members can access only their authorized private data.
- Authentication secrets are never committed to the repository.

## Current status

Foundation planning is complete. Production implementation should follow the repository technical blueprint and product/business specifications.
