-- Deep backend audit hardening: concurrency and winner identity invariants.

begin;

-- A person can only have one monthly-winner record per cycle.
-- Multiple selected memberships for the same person are represented by
-- monthly_winner_memberships, not duplicate monthly_winners rows.
create unique index if not exists monthly_winners_cycle_person_key
  on public.monthly_winners(cycle_id,person_id);

-- A membership may be selected only once per draw, and each selection
-- position may occur only once per draw.
create unique index if not exists draw_selections_draw_membership_key
  on public.draw_selections(draw_session_id,membership_id);

create unique index if not exists draw_selections_draw_order_key
  on public.draw_selections(draw_session_id,selection_order);

-- Serialize preparation against concurrent preparation calls by locking
-- the cycle row before creating/finding its draw session.
create or replace function public.prepare_draw_for_admin(target_cycle_id uuid)
returns uuid
language plpgsql
security definer
set search_path='public'
as $function$
declare
  session_id uuid;
  cycle_kuri_id uuid;
  cycle_status_value public.cycle_status;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select c.kuri_id,c.status
    into cycle_kuri_id,cycle_status_value
  from public.cycles c
  join public.kuris k on k.id=c.kuri_id
  where c.id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  for update of c;

  if cycle_kuri_id is null then raise exception 'You do not have permission to manage this draw.'; end if;
  if cycle_status_value not in ('PAYMENT_CLOSED','DRAW_PENDING') then
    raise exception 'Cycle must be PAYMENT_CLOSED or DRAW_PENDING before preparing a draw.';
  end if;

  select d.id into session_id
  from public.draw_sessions d
  where d.cycle_id=target_cycle_id
  for update;

  if session_id is null then
    insert into public.draw_sessions(kuri_id,cycle_id,conducted_by,status,started_at)
    values(cycle_kuri_id,target_cycle_id,(select id from public.users where id=auth.uid()),'DRAFT',now())
    returning id into session_id;
  end if;

  if (select ds.kuri_id from public.draw_sessions ds where ds.id=session_id) <> cycle_kuri_id then
    raise exception 'Draw session Kuri does not match the cycle Kuri.';
  end if;

  if (select ds.status from public.draw_sessions ds where ds.id=session_id) not in ('DRAFT','POOL_READY') then
    raise exception 'Draw session is already finalized or otherwise unavailable for preparation.';
  end if;

  insert into public.draw_pool_entries(
    draw_session_id,membership_id,system_eligible,admin_included,override,override_reason,modified_by,modified_at
  )
  select session_id,m.id,
         (m.status='ACTIVE' and i.status in ('PAID','PAID_LATE')),
         (m.status='ACTIVE' and i.status in ('PAID','PAID_LATE')),
         false,null,
         (select id from public.users where id=auth.uid()),now()
  from public.memberships m
  join public.installments i on i.membership_id=m.id
  where i.cycle_id=target_cycle_id
    and m.kuri_id=cycle_kuri_id
  on conflict(draw_session_id,membership_id) do nothing;

  update public.draw_pool_entries e
  set system_eligible=(m.status='ACTIVE' and i.status in ('PAID','PAID_LATE')),
      admin_included=case
        when e.override then e.admin_included
        else (m.status='ACTIVE' and i.status in ('PAID','PAID_LATE'))
      end,
      override=case when e.override then e.override else false end,
      override_reason=case when e.override then e.override_reason else null end,
      modified_by=(select id from public.users where id=auth.uid()),
      modified_at=now()
  from public.memberships m
  join public.installments i on i.membership_id=m.id
  where e.draw_session_id=session_id
    and e.membership_id=m.id
    and i.cycle_id=target_cycle_id
    and m.kuri_id=cycle_kuri_id;

  delete from public.draw_selections where draw_session_id=session_id;

  if (select status from public.draw_sessions where id=session_id)='DRAFT' then
    perform public.transition_draw_status_for_admin(session_id,'POOL_READY');
  end if;

  return session_id;
end;
$function$;

create or replace function public.run_random_draw_for_admin(
  target_cycle_id uuid, selection_count integer default 1
)
returns table(
  selection_order integer,
  membership_id uuid,
  membership_number text,
  registered_name text,
  display_name text,
  randomization_id text
)
language plpgsql
security definer
set search_path='public'
as $function$
declare
  session_id uuid;
  candidate_count integer;
  draw_status_value public.draw_status;
  cycle_status_value public.cycle_status;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if selection_count is null or selection_count<1 then raise exception 'Selection count must be at least 1.'; end if;

  select d.id,d.status,c.status
    into session_id,draw_status_value,cycle_status_value
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where d.cycle_id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  for update of d;

  if session_id is null then raise exception 'Prepare the draw first.'; end if;
  if cycle_status_value<>'DRAW_PENDING' then raise exception 'Cycle must be DRAW_PENDING before running the draw.'; end if;
  if draw_status_value<>'POOL_READY' then raise exception 'Draw must be POOL_READY before running the random draw.'; end if;

  if exists (
    select 1
    from public.draw_pool_entries e
    join public.memberships m on m.id=e.membership_id
    join public.installments i on i.membership_id=m.id and i.cycle_id=target_cycle_id
    where e.draw_session_id=session_id
      and e.admin_included
      and not (m.status='ACTIVE' and i.status in ('PAID','PAID_LATE'))
      and not e.override
  ) then
    raise exception 'Draw pool contains an ineligible membership without an override.';
  end if;

  select count(*) into candidate_count
  from public.draw_pool_entries e
  where e.draw_session_id=session_id and e.admin_included;

  if candidate_count=0 then raise exception 'No memberships are included in the draw pool.'; end if;
  if selection_count>candidate_count then raise exception 'Selection count exceeds the draw pool.'; end if;

  perform public.transition_draw_status_for_admin(session_id,'DRAWING');

  delete from public.draw_selections where draw_session_id=session_id;

  insert into public.draw_selections(draw_session_id,membership_id,selection_order,randomization_id)
  select session_id,picked.membership_id,picked.rn,gen_random_uuid()::text
  from (
    select e.membership_id,
           row_number() over(order by random())::integer rn
    from public.draw_pool_entries e
    where e.draw_session_id=session_id
      and e.admin_included
    order by random()
    limit selection_count
  ) picked;

  perform public.transition_draw_status_for_admin(session_id,'RESULTS_READY');

  return query
  select s.selection_order,s.membership_id,m.membership_number,
         p.registered_name,p.display_name,s.randomization_id
  from public.draw_selections s
  join public.memberships m on m.id=s.membership_id
  join public.people p on p.id=m.person_id
  where s.draw_session_id=session_id
  order by s.selection_order;
end;
$function$;

create or replace function public.finalize_draw_for_admin(
  target_cycle_id uuid, final_membership_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path='public'
as $function$
declare
  session_id uuid;
  target_kuri_id uuid;
  winner_count integer;
  selected_count integer;
  cycle_status_value public.cycle_status;
  draw_status_value public.draw_status;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  if final_membership_ids is null
     or coalesce(array_length(final_membership_ids,1),0)<1 then
    raise exception 'Select at least one winner.';
  end if;

  if cardinality(final_membership_ids) <>
     cardinality(array(select distinct unnest(final_membership_ids))) then
    raise exception 'Duplicate winner memberships are not allowed.';
  end if;

  select d.id,c.kuri_id,c.status,d.status
    into session_id,target_kuri_id,cycle_status_value,draw_status_value
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where d.cycle_id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  for update of d;

  if session_id is null then raise exception 'Prepare and run the draw before finalizing winners.'; end if;
  if cycle_status_value<>'DRAW_PENDING' then raise exception 'Cycle must be DRAW_PENDING before finalizing winners.'; end if;
  if draw_status_value<>'RESULTS_READY' then raise exception 'Draw must have RESULTS_READY status before finalizing winners.'; end if;

  if exists (select 1 from public.monthly_winners where cycle_id=target_cycle_id) then
    raise exception 'Winners are already finalized for this cycle.';
  end if;

  select count(*) into selected_count
  from public.draw_selections s
  where s.draw_session_id=session_id and s.membership_id=any(final_membership_ids);

  if selected_count<>array_length(final_membership_ids,1) then
    raise exception 'Final winners must come from the current draw selections.';
  end if;

  if exists (
    select 1
    from public.draw_selections s
    join public.memberships m on m.id=s.membership_id
    where s.draw_session_id=session_id
      and s.membership_id=any(final_membership_ids)
      and (m.kuri_id<>target_kuri_id or m.status<>'ACTIVE')
  ) then
    raise exception 'A final winner must be an ACTIVE membership in the draw Kuri.';
  end if;

  insert into public.monthly_winners(
    cycle_id,person_id,selection_source,finalized_by,finalized_at
  )
  select target_cycle_id,m.person_id,'RANDOM_DRAW',
         (select id from public.users where id=auth.uid()),now()
  from public.memberships m
  where m.id=any(final_membership_ids)
  group by m.person_id;

  insert into public.monthly_winner_memberships(monthly_winner_id,membership_id)
  select mw.id,m.id
  from public.monthly_winners mw
  join public.memberships m on m.person_id=mw.person_id
  where mw.cycle_id=target_cycle_id
    and m.id=any(final_membership_ids);

  perform public.transition_draw_status_for_admin(session_id,'FINALIZED');
  perform public.transition_cycle_status_for_admin(target_cycle_id,'COMPLETED');

  select count(*) into winner_count
  from public.monthly_winners where cycle_id=target_cycle_id;

  return winner_count;
end;
$function$;

revoke all on function public.prepare_draw_for_admin(uuid) from public;
revoke all on function public.run_random_draw_for_admin(uuid,integer) from public;
revoke all on function public.finalize_draw_for_admin(uuid,uuid[]) from public;
grant execute on function public.prepare_draw_for_admin(uuid) to authenticated;
grant execute on function public.run_random_draw_for_admin(uuid,integer) to authenticated;
grant execute on function public.finalize_draw_for_admin(uuid,uuid[]) to authenticated;

commit;