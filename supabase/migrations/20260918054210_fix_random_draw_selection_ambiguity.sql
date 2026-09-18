begin;

create or replace function public.run_random_draw_for_admin(
  target_cycle_id uuid,
  selection_count integer default 1
)
returns table (
  selection_order integer,
  membership_id uuid,
  membership_number text,
  registered_name text,
  display_name text,
  randomization_id text
)
language plpgsql
security definer
set search_path=public
as $$
declare
  session_id uuid;
  candidate_count integer;
begin
  if selection_count is null or selection_count < 1 then
    raise exception 'Selection count must be at least 1.';
  end if;

  select d.id
    into session_id
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where d.cycle_id=target_cycle_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );

  if session_id is null then
    raise exception 'Prepare the draw first.';
  end if;

  select count(*)
    into candidate_count
  from public.draw_pool_entries e
  where e.draw_session_id=session_id
    and e.admin_included;

  if candidate_count=0 then
    raise exception 'No memberships are included in the draw pool.';
  end if;

  if selection_count>candidate_count then
    raise exception 'Selection count exceeds the draw pool.';
  end if;

  delete from public.draw_selections
  where draw_session_id=session_id;

  insert into public.draw_selections (
    draw_session_id,membership_id,selection_order,randomization_id
  )
  select
    session_id,
    picked.membership_id,
    picked.rn,
    gen_random_uuid()::text
  from (
    select
      e.membership_id,
      row_number() over (order by random())::integer as rn
    from public.draw_pool_entries e
    where e.draw_session_id=session_id
      and e.admin_included
    order by random()
    limit selection_count
  ) picked;

  update public.draw_sessions
  set status='RESULTS_READY',
      completed_at=now()
  where id=session_id;

  return query
  select
    s.selection_order,
    s.membership_id,
    m.membership_number,
    p.registered_name,
    p.display_name,
    s.randomization_id
  from public.draw_selections s
  join public.memberships m on m.id=s.membership_id
  join public.people p on p.id=m.person_id
  where s.draw_session_id=session_id
  order by s.selection_order;
end;
$$;

revoke all on function public.run_random_draw_for_admin(uuid,integer) from public;
grant execute on function public.run_random_draw_for_admin(uuid,integer) to authenticated;

commit;