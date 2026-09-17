begin;

-- The People page uses a SECURITY DEFINER RPC. PostgREST still needs execute
-- access to the function, while the function itself performs the admin check.
-- Keep direct table access out of the client path.
revoke all on function public.list_people_for_admin() from public;
grant execute on function public.list_people_for_admin() to authenticated;

after insert on public.people;

commit;
