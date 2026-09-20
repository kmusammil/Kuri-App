# Authenticated API Integration Tests

This suite exercises the Kuri-App backend through Supabase Auth + PostgREST RPCs using real JWT sessions.

## Why this exists

The SQL regression suite verifies database invariants, privileges, function definitions, and existing data. A privileged SQL connection cannot prove the behavior of a real authenticated client. This suite is the JWT-level complement.

## Test identities

- Org A ADMIN
- Org B ADMIN
- Org A ordinary member
- anonymous client (no session)

Use dedicated test-only Auth users. Do not use a personal account and do not commit passwords or tokens.

## Fixture requirements

Set these environment variables:

- TEST_PERSON_A_ID and TEST_KURI_A_ID: objects in Org A
- TEST_PERSON_B_ID and TEST_KURI_B_ID: objects in Org B
- TEST_CYCLE_A_ID: a cycle in Org A

The suite intentionally uses read operations and rejected mutations where possible so ordinary runs do not create disposable financial records.

## Run

Install dependencies, then run:

    npm run test:integration

The command uses the dedicated Vitest integration configuration.

## What it proves

- real Auth sessions can reach the RPC boundary;
- anonymous requests are rejected;
- authenticated ADMIN access works inside the tenant;
- cross-tenant Kuri/person access is rejected;
- ordinary members cannot use administrative RPCs;
- internal lifecycle transition RPCs are not exposed;
- list APIs remain tenant-scoped;
- cross-tenant payment creation is rejected before mutation;
- unauthenticated payment creation is rejected.

## What it does not yet prove

It does not create/settle real financial fixtures, run destructive lifecycle operations, or claim concurrency coverage. Those should be added as isolated disposable fixtures once a dedicated integration-test workspace strategy is established.
