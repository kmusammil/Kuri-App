begin;

-- These lifecycle transitions are part of the existing client-facing dashboard
-- contract. The functions perform their own auth.uid(), organization/role,
-- state-machine, and row-lock checks. They are intentionally available to
-- authenticated clients but never to anonymous/public callers.
grant execute on function public.transition_kuri_status_for_admin(uuid,public.kuri_status) to authenticated;
grant execute on function public.transition_cycle_status_for_admin(uuid,public.cycle_status) to authenticated;
grant execute on function public.transition_draw_status_for_admin(uuid,public.draw_status) to authenticated;

revoke execute on function public.transition_kuri_status_for_admin(uuid,public.kuri_status) from anon, public;
revoke execute on function public.transition_cycle_status_for_admin(uuid,public.cycle_status) from anon, public;
revoke execute on function public.transition_draw_status_for_admin(uuid,public.draw_status) from anon, public;

commit;
