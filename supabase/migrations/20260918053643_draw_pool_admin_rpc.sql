begin;

create or replace function public.get_draw_selections_for_admin(target_cycle_id uuid)
returns table (
  selection_id uuid,
  selection_order integer,
  membership_id uuid,
  membership_number text,
  registered_name text,
  display_name text,
  randomization_id text,
  selected_at timestamptz
)
language sql security definer set search_path=public stable
as $$
  select
    s.id,s.selection_order,m.id,m.membership_number,p.registered_name,p.display_name,
    s.randomization_id,s.selected_at
  from public.draw_selections s
  join public.draw_sessions d on d.id=s.draw_session_id
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  join public.memberships m on m.id=s.membership_id
  join public.people p on p.id=m.person_id
  where c.id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  order by s.selection_order;
$$;

revoke all on function public.get_draw_selections_for_admin(uuid) from public;
grant execute on function public.get_draw_selections_for_admin(uuid) to authenticated;

commit;