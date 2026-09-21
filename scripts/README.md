# Local load-fixture generator

This tooling generates deterministic synthetic Kuri-App data locally.

Generate 10,000 people:

    node scripts/generate-load-fixture.mjs

Generate 20,000 people:

    node scripts/generate-load-fixture.mjs --people 20000

Reproduce a fixture:

    node scripts/generate-load-fixture.mjs --people 10000 --seed 20260921

The output goes under .tmp/ and is not intended for source control.

This phase performs no hosted Supabase operation and no billable test.