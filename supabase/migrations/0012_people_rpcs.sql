begin;

-- The people admin SELECT policy joins through organization_users.
-- PostgreSQL still needs table privileges for that relation and its nested
-- membership evaluation path.
grant select on table public.memberships to authenticated;
grant select on table public.kuris to authenticated;

commit;
