# Supabase Migration History

## Production database is the authority

The linked Supabase project has an existing migration ledger in `supabase_migrations.schema_migrations`. Some older migration source files were intentionally removed or superseded in Git history after their changes had already been applied remotely.

Do not use `supabase migration repair` as a bulk cleanup mechanism, and do not delete remote migration-history rows merely to make `supabase migration list` look symmetrical. A repair changes migration metadata; it does not apply or revert schema changes.

## Current policy

- Preserve the remote migration ledger as historical record.
- Preserve the live production schema and data.
- Keep future migrations in `supabase/migrations/` and apply them through the normal migration workflow.
- When a migration is applied directly through Supabase tooling, record the exact generated remote version in GitHub rather than inventing a different timestamp later.
- Treat older missing/superseded migration files as historical repository drift, not as a reason to rewrite production history.

## Known baseline boundary

The repository contains the current canonical SQL needed for ongoing development, including the later hardening migrations that correspond to the applied production changes. Historical migrations that were superseded are not recreated solely for cosmetic migration-list parity.

Before introducing a new production migration workflow, verify the local/remote migration state explicitly and use a reviewed baseline procedure rather than ad-hoc repairs.

## 2026-09-25 ledger-driven update

The migration `20260925072540_identity_organization_authority_v1` was applied to the linked Supabase project. It is the first migration introduced after the 2026-09-22 backend freeze record was superseded by the Master Backend Improvement Ledger. It adds explicit organization type/context and Kuri-scoped authority without rewriting historical records.
