begin;

-- Supabase/PostgREST requires table privileges in addition to RLS policies.
-- Grant authenticated users table-level DML so the RLS policies can decide
-- whether a signed-in admin may create, update, or delete Kuri records.
grant select, insert, update, delete on table public.kuris to authenticated;

commit;
