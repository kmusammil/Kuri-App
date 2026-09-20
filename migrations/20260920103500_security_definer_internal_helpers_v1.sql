begin;
revoke all on function public.handle_new_auth_user() from public;
revoke all on function public.has_org_role(uuid, public.app_role[]) from public;
revoke all on function public.is_org_member(uuid) from public;
revoke all on function public.create_isolated_state_machine_test_kuri() from public;
commit;