# Kuri-App Foundation Manifest

This manifest defines the files to add in the foundation build.

## Stack
- Next.js App Router
- TypeScript
- Tailwind CSS
- Supabase PostgreSQL/Auth/Storage
- Zod
- Vitest
- Playwright

## Foundation scope
- Browser-visible app shell
- Supabase server/browser clients
- Environment template
- SQL migration with core Kuri domain tables, enums, constraints, helper functions, trigger-based audit support, and RLS
- Authentication routes and role-aware middleware foundation
- Shared validation/types placeholders
- Test configuration
- Documentation updates

## Important
Secrets are never committed. `.env.example` contains variable names only. The migration is designed around organizations, users, people, memberships, cycles, installments, payments, payment allocations, Muppu, draw sessions/pools/selections, monthly winners, winner memberships, payouts, exits, nominees, files, and audit logs.
