begin;

create or replace function public.get_draw_session_for_admin(target_cycle_id uuid)
returns table (
  id uuid, kuri_id uuid, cycle_id uuid, conducted_by uuid,
  status public.draw_status, started_at timestamptz, completed_at timestamptz, created_at timestamptz
)
language sql security definer set search_path=public stable
as $$
  select d.id,d.kuri_id,d.cycle_id,d.conducted_by,d.status,d.started_at,d.completed_at,d.created_at
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where d.cycle_id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$$;

create or replace function public.prepare_draw_for_admin(target_cycle_id uuid)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare session_id uuid; cycle_kuri_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select c.kuri_id into cycle_kuri_id from public.cycles c join public.kuris k on k.id=c.kuri_id
  where c.id=target_cycle_id and exists (
    select 1 from public.organization_users ou
    where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  );
  if cycle_kuri_id is null then raise exception 'You do not have permission to manage this draw.'; end if;

  select d.id into session_id from public.draw_sessions d where d.cycle_id=target_cycle_id;
  if session_id is null then
    insert into public.draw_sessions(kuri_id,cycle_id,conducted_by,status,started_at)
    values(cycle_kuri_id,target_cycle_id,(select id from public.users where id=auth.uid()),'POOL_READY',now())
    returning id into session_id;
  end if;

  insert into public.draw_pool_entries(draw_session_id,membership_id,system_eligible,admin_included,override,modified_by,modified_at)
  select session_id,m.id,(i.status in ('PAID','PAID_LATE')),(i.status in ('PAID','PAID_LATE')),false,
         (select id from public.users where id=auth.uid()),now()
  from public.memberships m
  join public.installments i on i.membership_id=m.id
  where i.cycle_id=target_cycle_id
  on conflict(draw_session_id,membership_id) do nothing;

  return session_id;
end;
$$;

create or replace function public.list_draw_pool_for_admin(target_cycle_id uuid)
returns table (
  entry_id uuid, membership_id uuid, membership_number text,
  registered_name text, display_name text, system_eligible boolean,
  admin_included boolean, override boolean, override_reason text
)
language sql security definer set search_path=public stable
as $$
  select e.id,m.id,m.membership_number,p.registered_name,p.display_name,
         e.system_eligible,e.admin_included,e.override,e.override_reason
  from public.draw_pool_entries e
  join public.draw_sessions d on d.id=e.draw_session_id
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  join public.memberships m on m.id=e.membership_id
  join public.people p on p.id=m.person_id
  where c.id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  order by m.membership_number;
$$;

create or replace function public.set_draw_pool_entry_for_admin(
  target_entry_id uuid, include_in_draw boolean, override_reason text default null
)
returns void
language plpgsql security definer set search_path=public
as $$
declare org_id uuid;
begin
  select k.organization_id into org_id
  from public.draw_pool_entries e
  join public.draw_sessions d on d.id=e.draw_session_id
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where e.id=target_entry_id;

  if org_id is null then raise exception 'Draw pool entry not found.'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=org_id and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to modify this draw pool.'; end if;

  update public.draw_pool_entries
  set admin_included=include_in_draw,
      override=(include_in_draw<>system_eligible),
      override_reason=nullif(btrim(override_reason),''),
      modified_by=(select id from public.users where id=auth.uid()),
      modified_at=now()
  where id=target_entry_id;
end;
$$;

create or replace function public.run_random_draw_for_admin(target_cycle_id uuid, selection_count integer default 1)
returns table (
  selection_order integer, membership_id uuid, membership_number text,
  registered_name text, display_name text, randomization_id text
)
language plpgsql security definer set search_path=public
as $$
declare session_id uuid; candidate_count integer;
begin
  if selection_count is null or selection_count<1 then raise exception 'Selection count must be at least 1.'; end if;

  select d.id into session_id
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where d.cycle_id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
  if session_id is null then raise exception 'Prepare the draw first.'; end if;

  select count(*) into candidate_count
  from public.draw_pool_entries e
  where e.draw_session_id=session_id and e.admin_included;
  if candidate_count=0 then raise exception 'No memberships are included in the draw pool.'; end if;
  if selection_count>candidate_count then raise exception 'Selection count exceeds the draw pool.'; end if;

  delete from public.draw_selections where draw_session_id=session_id;

  insert into public.draw_selections(draw_session_id,membership_id,selection_order,randomization_id)
  select session_id,e.membership_id,row_number() over(order by random())::integer,gen_random_uuid()::text
  from public.draw_pool_entries e
  where e.draw_session_id=session_id and e.admin_included
  order by random()
  limit selection_count;

  update public.draw_sessions set status='RESULTS_READY',completed_at=now() where id=session_id;

  return query
  select s.selection_order,s.membership_id,m.membership_number,p.registered_name,p.display_name,s.randomization_id
  from public.draw_selections s
  join public.memberships m on m.id=s.membership_id
  join public.people p on p.id=m.person_id
  where s.draw_session_id=session_id
  order by s.selection_order;
end;
$$;

revoke all on function public.get_draw_session_for_admin(uuid) from public;
revoke all on function public.prepare_draw_for_admin(uuid) from public;
revoke all on function public.list_draw_pool_for_admin(uuid) from public;
revoke all on function public.set_draw_pool_entry_for_admin(uuid,boolean,text) from public;
revoke all on function public.run_random_draw_for_admin(uuid,integer) from public;
grant execute on function public.get_draw_session_for_admin(uuid) to authenticated;
grant execute on function public.prepare_draw_for_admin(uuid) to authenticated;
grant execute on function public.list_draw_pool_for_admin(uuid) to authenticated;
grant execute on function public.set_draw_pool_entry_for_admin(uuid,boolean,text) to authenticated;
grant execute on function public.run_random_draw_for_admin(uuid,integer) to authenticated;

commit;