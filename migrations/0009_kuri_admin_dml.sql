begin;

-- Supabase/PostgREST requires table privileges in addition to RLS policies.
-- RLS policies still control which rows authenticated users may access.
grant select, insert, update, delete on table public.kuris to authenticated;

commit;
