begin;

-- Internal lifecycle transition primitives are callable only by higher-level
-- database routines. They are intentionally removed from the client-facing
-- Data API while remaining executable by their owning database role.
revoke execute on function public.transition_kuri_status_for_admin(uuid,public.kuri_status) from public, anon, authenticated;
revoke execute on function public.transition_cycle_status_for_admin(uuid,public.cycle_status) from public, anon, authenticated;
revoke execute on function public.transition_draw_status_for_admin(uuid,public.draw_status) from public, anon, authenticated;

commit;
