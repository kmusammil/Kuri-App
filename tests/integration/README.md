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

The current fixture is intentionally non-destructive. Positive end-to-end financial/draw tests require additional disposable records and are kept separate from the 27-test boundary suite until their cleanup path is automated.

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

The current local run passes **27/27 authenticated integration tests** using real Supabase Auth sessions.

## Next integration layer

The next layer will use an isolated disposable Kuri fixture to test the full positive workflow:

1. create Kuri;
2. create people/memberships;
3. generate installments;
4. create and allocate payment;
5. advance cycle lifecycle;
6. prepare/run/finalize draw;
7. prepare and mark payout paid;
8. verify financial and winner invariants;
9. run concurrent draw/payment/settlement race tests;
10. clean up all disposable fixture data.

Those tests should never reuse production/business records.
