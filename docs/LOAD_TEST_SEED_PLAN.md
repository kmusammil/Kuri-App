# Kuri-App Synthetic Load Seed Plan

## Purpose
Create a disposable, domain-aware synthetic dataset for backend and later full-stack testing without using business data.

This phase is local-only by design. The seed generator must not connect to or mutate the hosted Supabase project unless a future run explicitly enables that.

## Target scale
- Primary target: 10,000 synthetic people.
- Supported upper target: 20,000 synthetic people.
- Generate related records from real Kuri-App relationships rather than unrelated random rows.

Expected domains include people, contacts, Kuris, cycles, memberships, installments, payments, allocations, draws, winners, payouts, nominees, exits/refunds, and Muppu.

## Safety rules
1. Never use real customer/business data.
2. Never require or read a production service_role key for the local generator.
3. Never mutate the hosted Supabase project by default.
4. The default command only generates a local fixture.
5. Any future database loader must require explicit opt-in and a clearly identified non-production target.
6. Do not create a Supabase branch without explicit cost approval.

## Phases
### A — local fixture generation
Generate deterministic synthetic records locally. No Supabase network/database operation.

### B — local database execution
Load the fixture into a local Postgres/Supabase environment and verify foreign keys, uniqueness, state machines, tenant boundaries, financial invariants, and representative queries.

### C — hosted test
Not authorized yet. Only perform this later if explicitly approved. This phase may consume hosted Supabase resources.

### D — frontend scale testing
After the frontend exists, use the same dataset to test pagination, filtering, search, sorting, dashboard queries, request volume, rendering, and mobile behavior.

## Initial distribution
- 10,000 people.
- 5–10 Kuris.
- Multiple cycles per Kuri.
- 1–2 memberships per person, subject to Kuri limits.
- Installments derived from memberships/cycles.
- Payments and allocations derived from installments.
- Representative nominees, exits, Muppu, draws, winners and payouts.
- Do not create every possible domain record for every person; the goal is realistic relational density.

## Exit criteria
- Deterministic local generator.
- 10,000-person fixture generated successfully.
- Expandable to 20,000.
- Domain relationships remain coherent.
- Fixture can later be loaded into a local database.
- Integrity and query/performance checks can be run before frontend pagination is finalized.

## Current status
Phase A is being implemented.
No hosted seed or billable test has been run or authorized.