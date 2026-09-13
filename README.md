# Kuri-App

Community Kuri management application.

## Stack

- Next.js
- React
- TypeScript
- Tailwind CSS
- Supabase (PostgreSQL, Auth, Storage, RLS)
- Zod
- Vitest
- Playwright

## Local development

1. Install Node.js.
2. Run `npm install`.
3. Copy `.env.example` to `.env.local`.
4. Add the Supabase project URL and public anon key.
5. Run `npm run dev`.

## Architecture

See `docs/TECHNICAL_BLUEPRINT.md` for the product and technical architecture. The application is being built incrementally, starting with the project foundation and database/auth infrastructure before the Kuri workflows.
