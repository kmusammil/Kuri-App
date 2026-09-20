# Authenticated API Integration Tests

This suite exercises the Kuri-App backend through Supabase Auth + PostgREST RPCs using real JWT sessions.

## Test identities

- Org A ADMIN
- Org B ADMIN
- Org A ordinary member
- anonymous client (no session)

Use dedicated test-only Auth users. Do not use a personal account and do not commit passwords or tokens.

## Current fixture

The authenticated boundary suite uses the existing dedicated integration-test workspace records through environment variables:

- TEST_PERSON_A_ID and TEST_KURI_A_ID
- TEST_PERSON_B_ID and TEST_KURI_B_ID
- TEST_CYCLE_A_ID

The boundary fixture is intentionally non-destructive. The positive workflow creates isolated Kuri records named `Integration E2E <timestamp>` in the dedicated Org A test workspace. Those records are not business data.

## Run

Install dependencies, then run:

    npm run test:integration

The command uses the dedicated Vitest integration configuration.

## Current coverage

The suite currently proves:

- real Supabase Auth sessions reach the RPC boundary;
- anonymous requests are rejected;
- authenticated ADMIN access works inside the tenant;
- cross-tenant Kuri/person access is rejected;
- ordinary members cannot use administrative RPCs;
- lifecycle transition RPCs are authenticated-only application APIs;
- list APIs remain tenant-scoped;
- cross-tenant payment creation is rejected before mutation;
- unauthenticated payment creation is rejected;
- ordinary members cannot create memberships;
- cross-tenant membership assignment is rejected;
- draw preparation, execution, and finalization are blocked before valid lifecycle prerequisites;
- payout preparation requires a real winner and tenant boundary;
- non-positive payments and invalid allocations are rejected;
- direct authenticated inserts into protected payment/draw tables are blocked;
- cross-tenant nominees and Muppu records are rejected;
- invalid membership-exit requests are rejected.

The current boundary suite passes **27/27 authenticated integration tests** using real Supabase Auth sessions.

## Positive workflow and concurrency

Run the isolated end-to-end workflow with:

    npm run test:integration:e2e

It exercises:

1. create Kuri;
2. generate its cycle;
3. open the Kuri;
4. create a membership;
5. verify generated installment;
6. create and allocate a payment;
7. advance the cycle through OPEN -> PAYMENT_CLOSED -> DRAW_PENDING;
8. prepare the draw;
9. run two concurrent random-draw requests and require exactly one success;
10. finalize the selected winner;
11. prepare the payout;
12. run two concurrent payout-payment requests and require exactly one success;
13. verify the payout is PAID with the expected net amount;
14. return the Kuri to a safe ACTIVE state.

The workflow creates disposable records and therefore is intentionally separate from the non-destructive 27-test boundary suite.

After a successful or failed run, use `tests/integration/cleanup-positive-fixtures.sql` in the Supabase SQL editor to remove only the `Integration E2E %` fixtures from the dedicated test organization. Do not run it against business/test data outside that organization.
