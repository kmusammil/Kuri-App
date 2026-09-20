begin;

create or replace function public.get_membership_exit_membership_id_for_admin(target_exit_id uuid)
returns uuid
language sql
security definer
set search_path=public
stable
as $$
  select me.membership_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$$;

revoke all on function public.get_membership_exit_membership_id_for_admin(uuid) from public;
grant execute on function public.get_membership_exit_membership_id_for_admin(uuid) to authenticated;

commit;
