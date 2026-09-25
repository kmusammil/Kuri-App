begin;

-- Reconcile remaining Kuri-scoped administrative RPCs with explicit Kuri authority.
-- Organization-scoped person/payment operations intentionally remain separate.

CREATE OR REPLACE FUNCTION public.generate_cycles_for_admin(target_kuri_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  kuri_org_id uuid;
  v_cycle_id uuid;
  cycle_start date;
  cycle_end date;
  due_date date;
  draw_date date;
  cycle_no integer;
  inserted_cycles integer := 0;
  cycle_memberships integer;
  total_cycles integer;
  membership_amount bigint;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.organization_id, k.start_date, k.number_of_cycles, k.installment_amount
    into kuri_org_id, cycle_start, total_cycles, membership_amount
  from public.kuris k
  where k.id = target_kuri_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  limit 1;

  if kuri_org_id is null then
    raise exception 'You do not have permission to manage cycles for this Kuri.';
  end if;

  for cycle_no in 1..total_cycles loop
    cycle_start := (select k.start_date from public.kuris k where k.id = target_kuri_id) + ((cycle_no - 1) * interval '1 month');
    cycle_end := (cycle_start + interval '1 month' - interval '1 day')::date;

    select make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(
        (select k.due_day from public.kuris k where k.id = target_kuri_id),
        extract(day from (date_trunc('month', cycle_start) + interval '1 month - 1 day'))::integer
      )
    ) into due_date;

    select make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(
        (select k.draw_day from public.kuris k where k.id = target_kuri_id),
        extract(day from (date_trunc('month', cycle_start) + interval '1 month - 1 day'))::integer
      )
    ) into draw_date;

    insert into public.cycles (
      kuri_id, cycle_number, period_start, period_end, due_date, draw_date, status
    ) values (
      target_kuri_id, cycle_no, cycle_start, cycle_end, due_date, draw_date, 'UPCOMING'
    )
    on conflict (kuri_id, cycle_number) do update
      set period_start = excluded.period_start,
          period_end = excluded.period_end,
          due_date = excluded.due_date,
          draw_date = excluded.draw_date;

    select c.id into v_cycle_id
    from public.cycles c
    where c.kuri_id = target_kuri_id
      and c.cycle_number = cycle_no;

    insert into public.installments (
      membership_id, cycle_id, amount_due, amount_paid, status, due_date
    )
    select
      m.id, v_cycle_id, membership_amount, 0, 'UNPAID', due_date
    from public.memberships m
    where m.kuri_id = target_kuri_id
      and not exists (
        select 1
        from public.installments i
        where i.membership_id = m.id
          and i.cycle_id = v_cycle_id
      )
    on conflict (membership_id, cycle_id) do nothing;

    inserted_cycles := inserted_cycles + 1;
  end loop;

  select count(*) into cycle_memberships
  from public.memberships m
  where m.kuri_id = target_kuri_id;

  return inserted_cycles;
end;
$function$;

CREATE OR REPLACE FUNCTION public.generate_kuri_schedule_for_admin(target_kuri_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  kuri_row public.kuris%rowtype;
  current_cycle_id uuid;
  membership_count integer;
  created_cycles integer := 0;
  cycle_start date;
  cycle_end date;
  due_date date;
  draw_date date;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.* into kuri_row
  from public.kuris k
  where k.id = target_kuri_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);

  if not found then
    raise exception 'You do not have permission to manage this Kuri.';
  end if;

  select count(*) into membership_count
  from public.memberships m
  where m.kuri_id = target_kuri_id;

  if membership_count = 0 then
    raise exception 'Add at least one membership before generating the schedule.';
  end if;

  for i in 1..kuri_row.number_of_cycles loop
    cycle_start := (kuri_row.start_date + ((i - 1) * interval '1 month'))::date;
    cycle_end := (cycle_start + interval '1 month' - interval '1 day')::date;
    due_date := make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.due_day, extract(day from cycle_end)::integer)
    );
    draw_date := make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.draw_day, extract(day from cycle_end)::integer)
    );

    current_cycle_id := null;

    insert into public.cycles (
      kuri_id, cycle_number, period_start, period_end, due_date, draw_date, status
    )
    values (
      target_kuri_id, i, cycle_start, cycle_end, due_date, draw_date, 'UPCOMING'
    )
    on conflict (kuri_id, cycle_number) do nothing
    returning id into current_cycle_id;

    if current_cycle_id is null then
      select c.id into current_cycle_id
      from public.cycles c
      where c.kuri_id = target_kuri_id
        and c.cycle_number = i;
    else
      created_cycles := created_cycles + 1;
    end if;

    insert into public.installments (
      membership_id, cycle_id, amount_due, amount_paid, status, due_date
    )
    select
      m.id,
      current_cycle_id,
      kuri_row.installment_amount,
      0,
      'UNPAID',
      due_date
    from public.memberships m
    where m.kuri_id = target_kuri_id
    on conflict (membership_id, cycle_id) do nothing;
  end loop;

  return created_cycles;
end;
$function$;

CREATE OR REPLACE FUNCTION public.transition_kuri_status_for_admin(target_kuri_id uuid, target_status kuri_status)
 RETURNS kuri_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_status public.kuri_status; org_id uuid; configured_cycles integer; actual_cycles integer; nonterminal_cycles integer;
begin
 if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
 select k.status,k.organization_id,k.number_of_cycles into current_status,org_id,configured_cycles from public.kuris k where k.id=target_kuri_id for update;
 if org_id is null then raise exception 'Kuri not found.'; end if;
 if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to change this Kuri status.'; end if;
 if current_status=target_status then return current_status; end if;
 if not ((current_status='DRAFT' and target_status='OPEN') or (current_status='OPEN' and target_status='ACTIVE') or (current_status='ACTIVE' and target_status='COMPLETED') or (current_status='COMPLETED' and target_status='ARCHIVED')) then raise exception 'Invalid Kuri status transition: % -> %.',current_status,target_status; end if;
 if current_status='ACTIVE' and target_status='COMPLETED' then
   select count(*) into actual_cycles from public.cycles c where c.kuri_id=target_kuri_id;
   select count(*) into nonterminal_cycles from public.cycles c where c.kuri_id=target_kuri_id and c.status not in ('COMPLETED','CANCELLED');
   if actual_cycles<>configured_cycles then raise exception 'Kuri cannot be completed until all configured cycles exist.'; end if;
   if nonterminal_cycles>0 then raise exception 'Kuri cannot be completed while cycles are not completed or cancelled.'; end if;
 end if;
 update public.kuris set status=target_status,updated_at=now() where id=target_kuri_id;
 return target_status;
end;
$function$;

CREATE OR REPLACE FUNCTION public.transition_cycle_status_for_admin(target_cycle_id uuid, target_status cycle_status)
 RETURNS cycle_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_status public.cycle_status; org_id uuid; target_kuri_id uuid; finalized_draw_count integer; winner_count integer;
begin
 if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
 select c.status,c.kuri_id,k.organization_id into current_status,target_kuri_id,org_id from public.cycles c join public.kuris k on k.id=c.kuri_id where c.id=target_cycle_id for update;
 if org_id is null then raise exception 'Cycle not found.'; end if;
 if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to change this cycle status.'; end if;
 if current_status=target_status then return current_status; end if;
 if not ((current_status='UPCOMING' and target_status='OPEN') or (current_status='OPEN' and target_status='PAYMENT_CLOSED') or (current_status='PAYMENT_CLOSED' and target_status='DRAW_PENDING') or (current_status='DRAW_PENDING' and target_status='COMPLETED') or (current_status in ('UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING') and target_status='CANCELLED')) then raise exception 'Invalid cycle status transition: % -> %.',current_status,target_status; end if;
 if current_status='DRAW_PENDING' and target_status='COMPLETED' then
   select count(*) into finalized_draw_count from public.draw_sessions d where d.cycle_id=target_cycle_id and d.kuri_id=target_kuri_id and d.status='FINALIZED';
   select count(*) into winner_count from public.monthly_winners mw where mw.cycle_id=target_cycle_id;
   if finalized_draw_count<>1 then raise exception 'Cycle cannot be completed until its draw is FINALIZED.'; end if;
   if winner_count<1 then raise exception 'Cycle cannot be completed without at least one finalized winner.'; end if;
 end if;
 update public.cycles set status=target_status where id=target_cycle_id;
 return target_status;
end;
$function$;

CREATE OR REPLACE FUNCTION public.transition_draw_status_for_admin(target_draw_session_id uuid, target_status draw_status)
 RETURNS draw_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare current_status public.draw_status; org_id uuid; target_cycle_id uuid; included_count integer; selection_count integer; winner_count integer; cycle_status public.cycle_status;
begin
 if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
 select d.status,d.cycle_id,k.organization_id,c.status into current_status,target_cycle_id,org_id,cycle_status from public.draw_sessions d join public.kuris k on k.id=d.kuri_id join public.cycles c on c.id=d.cycle_id where d.id=target_draw_session_id for update;
 if org_id is null then raise exception 'Draw session not found.'; end if;
 if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to change this draw status.'; end if;
 if current_status=target_status then return current_status; end if;
 if not ((current_status='DRAFT' and target_status='POOL_READY') or (current_status='POOL_READY' and target_status in ('DRAWING','CANCELLED')) or (current_status='DRAWING' and target_status in ('RESULTS_READY','CANCELLED')) or (current_status='RESULTS_READY' and target_status='FINALIZED')) then raise exception 'Invalid draw status transition: % -> %.',current_status,target_status; end if;
 if target_status='POOL_READY' then
   select count(*) into included_count from public.draw_pool_entries e where e.draw_session_id=target_draw_session_id and e.admin_included;
   if included_count<1 then raise exception 'Draw cannot become POOL_READY without an included pool entry.'; end if;
 elsif target_status='DRAWING' then
   if cycle_status<>'DRAW_PENDING' then raise exception 'Draw can only start while the cycle is DRAW_PENDING.'; end if;
   select count(*) into included_count from public.draw_pool_entries e where e.draw_session_id=target_draw_session_id and e.admin_included;
   if included_count<1 then raise exception 'Draw cannot start without an included pool.'; end if;
 elsif target_status='RESULTS_READY' then
   select count(*) into selection_count from public.draw_selections s where s.draw_session_id=target_draw_session_id;
   if selection_count<1 then raise exception 'Draw cannot become RESULTS_READY without selections.'; end if;
 elsif target_status='FINALIZED' then
   if cycle_status<>'DRAW_PENDING' then raise exception 'Draw cannot be finalized unless the cycle is DRAW_PENDING.'; end if;
   select count(*) into selection_count from public.draw_selections s where s.draw_session_id=target_draw_session_id;
   select count(*) into winner_count from public.monthly_winners mw where mw.cycle_id=target_cycle_id;
   if selection_count<1 then raise exception 'Draw cannot be finalized without selections.'; end if;
   if winner_count<1 then raise exception 'Draw cannot be finalized before at least one winner is finalized.'; end if;
 end if;
 update public.draw_sessions set status=target_status,started_at=case when target_status='DRAWING' then coalesce(started_at,now()) else started_at end,completed_at=case when target_status in ('RESULTS_READY','FINALIZED','CANCELLED') then coalesce(completed_at,now()) else completed_at end where id=target_draw_session_id;
 return target_status;
end;
$function$;

CREATE OR REPLACE FUNCTION public.prepare_draw_for_admin(target_cycle_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
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

CREATE OR REPLACE FUNCTION public.set_draw_pool_entry_for_admin(target_entry_id uuid, include_in_draw boolean, reason_text text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  org_id uuid;
  session_status public.draw_status;
  system_eligible_value boolean;
begin
  select k.organization_id,d.status,e.system_eligible
    into org_id,session_status,system_eligible_value
  from public.draw_pool_entries e
  join public.draw_sessions d on d.id=e.draw_session_id
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where e.id=target_entry_id;

  if org_id is null then raise exception 'Draw pool entry not found.'; end if;
  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to modify this draw pool.';
  end if;
  if session_status<>'POOL_READY' then
    raise exception 'Draw pool can only be modified while the draw is POOL_READY.';
  end if;

  if include_in_draw and not system_eligible_value and nullif(btrim(reason_text),'') is null then
    raise exception 'Including a system-ineligible membership requires a reason.';
  end if;

  update public.draw_pool_entries
  set admin_included=include_in_draw,
      override=(include_in_draw<>system_eligible_value),
      override_reason=case
        when include_in_draw<>system_eligible_value then nullif(btrim(reason_text),'')
        else null
      end,
      modified_by=(select id from public.users where id=auth.uid()),
      modified_at=now()
  where id=target_entry_id;

  if not found then raise exception 'Draw pool entry not found.'; end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.run_random_draw_for_admin(target_cycle_id uuid, selection_count integer DEFAULT 1)
 RETURNS TABLE(selection_order integer, membership_id uuid, membership_number text, registered_name text, display_name text, randomization_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
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

CREATE OR REPLACE FUNCTION public.finalize_draw_for_admin(target_cycle_id uuid, final_membership_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
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

CREATE OR REPLACE FUNCTION public.get_draw_session_for_admin(target_cycle_id uuid)
 RETURNS TABLE(id uuid, kuri_id uuid, cycle_id uuid, conducted_by uuid, status draw_status, started_at timestamp with time zone, completed_at timestamp with time zone, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select d.id,d.kuri_id,d.cycle_id,d.conducted_by,d.status,d.started_at,d.completed_at,d.created_at
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where d.cycle_id=target_cycle_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

CREATE OR REPLACE FUNCTION public.get_draw_selections_for_admin(target_cycle_id uuid)
 RETURNS TABLE(selection_id uuid, selection_order integer, membership_id uuid, membership_number text, registered_name text, display_name text, randomization_id text, selected_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    s.id,
    s.selection_order,
    m.id,
    m.membership_number,
    p.registered_name,
    p.display_name,
    s.randomization_id,
    s.selected_at
  from public.draw_selections s
  join public.draw_sessions d on d.id=s.draw_session_id
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  join public.memberships m on m.id=s.membership_id
  join public.people p on p.id=m.person_id
  where c.id=target_cycle_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by s.selection_order;
$function$;

CREATE OR REPLACE FUNCTION public.list_draw_pool_for_admin(target_cycle_id uuid)
 RETURNS TABLE(entry_id uuid, membership_id uuid, membership_number text, registered_name text, display_name text, system_eligible boolean, admin_included boolean, override boolean, override_reason text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select e.id,m.id,m.membership_number,p.registered_name,p.display_name,e.system_eligible,e.admin_included,e.override,e.override_reason
  from public.draw_pool_entries e
  join public.draw_sessions d on d.id=e.draw_session_id
  join public.memberships m on m.id=e.membership_id
  join public.people p on p.id=m.person_id
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where c.id=target_cycle_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by m.membership_number;
$function$;

CREATE OR REPLACE FUNCTION public.get_monthly_winners_for_admin(target_cycle_id uuid)
 RETURNS TABLE(winner_id uuid, person_id uuid, registered_name text, display_name text, selection_source text, finalized_by uuid, finalized_at timestamp with time zone, membership_numbers text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select mw.id,mw.person_id,p.registered_name,p.display_name,mw.selection_source::text,
         mw.finalized_by,mw.finalized_at,
         string_agg(m.membership_number, ', ' order by m.membership_number)
  from public.monthly_winners mw
  join public.people p on p.id=mw.person_id
  left join public.monthly_winner_memberships mwm on mwm.monthly_winner_id=mw.id
  left join public.memberships m on m.id=mwm.membership_id
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where mw.cycle_id=target_cycle_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  group by mw.id,mw.person_id,p.registered_name,p.display_name,mw.selection_source,mw.finalized_by,mw.finalized_at
  order by mw.finalized_at,mw.id;
$function$;

CREATE OR REPLACE FUNCTION public.prepare_payout_for_admin(target_winner_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare payout_id uuid; winner_person_id uuid; winner_cycle_id uuid; gross_amount bigint; configured_muppu_amount bigint; deducted_muppu_amount bigint; payout_muppu_amount bigint; cycle_status_value public.cycle_status;
begin
select mw.person_id,mw.cycle_id,k.gross_prize_amount,k.muppu_amount,c.status into winner_person_id,winner_cycle_id,gross_amount,configured_muppu_amount,cycle_status_value
from public.monthly_winners mw join public.cycles c on c.id=mw.cycle_id join public.kuris k on k.id=c.kuri_id
where mw.id=target_winner_id and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
if winner_person_id is null then raise exception 'Monthly winner not found.'; end if;
if cycle_status_value<>'COMPLETED' then raise exception 'Cycle must be COMPLETED before preparing a payout.'; end if;
if gross_amount<=0 then raise exception 'Gross prize amount must be greater than zero.'; end if;
select coalesce(sum(mr.amount),0) into deducted_muppu_amount from public.muppu_records mr where mr.person_id=winner_person_id and mr.cycle_id=winner_cycle_id and mr.status='DEDUCTED';
payout_muppu_amount:=greatest(coalesce(configured_muppu_amount,0),deducted_muppu_amount);
insert into public.payouts(monthly_winner_id,gross_amount,muppu_amount,other_deductions,net_amount,status)
values(target_winner_id,gross_amount,payout_muppu_amount,0,greatest(gross_amount-payout_muppu_amount,0),'PENDING')
on conflict(monthly_winner_id) do update set gross_amount=excluded.gross_amount,muppu_amount=excluded.muppu_amount,net_amount=greatest(excluded.gross_amount-excluded.muppu_amount-public.payouts.other_deductions,0)
where public.payouts.status='PENDING'
returning id into payout_id;
if payout_id is null then select po.id into payout_id from public.payouts po where po.monthly_winner_id=target_winner_id; end if;
return payout_id;
end $function$;

CREATE OR REPLACE FUNCTION public.get_payout_for_admin(target_winner_id uuid)
 RETURNS TABLE(payout_id uuid, winner_id uuid, person_id uuid, registered_name text, display_name text, gross_amount bigint, muppu_amount bigint, other_deductions bigint, net_amount bigint, payment_date timestamp with time zone, method payment_method, reference_number text, status payout_status, processed_by uuid, notes text, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select po.id,mw.id,mw.person_id,p.registered_name,p.display_name,
         po.gross_amount,po.muppu_amount,po.other_deductions,po.net_amount,
         po.payment_date,po.method,po.reference_number,po.status,po.processed_by,po.notes,po.created_at
  from public.payouts po
  join public.monthly_winners mw on mw.id=po.monthly_winner_id
  join public.people p on p.id=mw.person_id
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where mw.id=target_winner_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

CREATE OR REPLACE FUNCTION public.list_payouts_for_admin(target_kuri_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(payout_id uuid, winner_id uuid, cycle_number integer, person_id uuid, registered_name text, display_name text, gross_amount bigint, muppu_amount bigint, other_deductions bigint, net_amount bigint, payment_date timestamp with time zone, method payment_method, reference_number text, status payout_status)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select po.id,mw.id,c.cycle_number,mw.person_id,p.registered_name,p.display_name,
         po.gross_amount,po.muppu_amount,po.other_deductions,po.net_amount,
         po.payment_date,po.method,po.reference_number,po.status
  from public.payouts po
  join public.monthly_winners mw on mw.id=po.monthly_winner_id
  join public.people p on p.id=mw.person_id
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where (target_kuri_id is null or k.id=target_kuri_id)
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by c.cycle_number desc,po.created_at desc;
$function$;

CREATE OR REPLACE FUNCTION public.mark_payout_paid_for_admin(target_winner_id uuid, payout_payment_date timestamp with time zone, payout_method payment_method, payout_reference text DEFAULT NULL::text, payout_notes text DEFAULT NULL::text, payout_other_deductions bigint DEFAULT 0)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare payout_row public.payouts%rowtype; target_org_id uuid; computed_net_amount bigint;
begin
if auth.uid() is null then raise exception 'You must be signed in.'; end if;
if payout_other_deductions<0 then raise exception 'Other deductions cannot be negative.'; end if;
perform public.prepare_payout_for_admin(target_winner_id);
select po.* into payout_row from public.payouts po join public.monthly_winners mw on mw.id=po.monthly_winner_id join public.cycles c on c.id=mw.cycle_id join public.kuris k on k.id=c.kuri_id where po.monthly_winner_id=target_winner_id for update;
if not found then raise exception 'Payout not found.'; end if;
select k.organization_id into target_org_id from public.monthly_winners mw join public.cycles c on c.id=mw.cycle_id join public.kuris k on k.id=c.kuri_id where mw.id=target_winner_id;
if target_org_id is null then raise exception 'Monthly winner not found.'; end if;
if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to process this payout.'; end if;
if payout_row.status<>'PENDING' then raise exception 'Only a PENDING payout can be marked PAID.'; end if;
perform public.transition_payout_status_for_admin(payout_row.id,'PROCESSING');
computed_net_amount:=greatest(payout_row.gross_amount-payout_row.muppu_amount-payout_other_deductions,0);
update public.payouts set other_deductions=payout_other_deductions,net_amount=computed_net_amount,payment_date=coalesce(payout_payment_date,now()),method=payout_method,reference_number=nullif(btrim(payout_reference),''),processed_by=(select id from public.users where id=auth.uid()),notes=nullif(btrim(payout_notes),'') where id=payout_row.id;
perform public.transition_payout_status_for_admin(payout_row.id,'PAID'); end $function$;

CREATE OR REPLACE FUNCTION public.transition_payout_status_for_admin(target_payout_id uuid, target_status payout_status)
 RETURNS payout_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_status public.payout_status;
  org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;

  select p.status,k.organization_id
    into current_status,org_id
  from public.payouts p
  join public.monthly_winners mw on mw.id=p.monthly_winner_id
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where p.id=target_payout_id
  for update;

  if org_id is null then raise exception 'Payout not found.'; end if;

  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to change this payout status.'; end if;

  if current_status=target_status then return current_status; end if;

  if not (
    (current_status='PENDING' and target_status in ('PROCESSING','CANCELLED'))
    or (current_status='PROCESSING' and target_status in ('PAID','CANCELLED'))
  ) then
    raise exception 'Invalid payout status transition: % -> %.', current_status, target_status;
  end if;

  update public.payouts set status=target_status where id=target_payout_id;
  return target_status;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_membership_exit_for_admin(target_membership_id uuid, exit_reason settlement_reason, target_exit_date date, target_refund_policy refund_policy DEFAULT 'AT_MATURITY'::refund_policy, target_refund_amount bigint DEFAULT NULL::bigint, target_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  target_kuri_id uuid;
  target_person_id uuid;
  current_membership_status public.membership_status;
  contributed_amount bigint:=0;
  calculated_refund bigint;
  exit_id_value uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if target_exit_date is null then raise exception 'Exit date is required.'; end if;

  select m.kuri_id,m.person_id,m.status
    into target_kuri_id,target_person_id,current_membership_status
  from public.memberships m
  join public.kuris k on k.id=m.kuri_id
  where m.id=target_membership_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update;

  if target_kuri_id is null then raise exception 'Membership not found or access denied.'; end if;
  if current_membership_status not in ('ACTIVE','SUSPENDED') then
    raise exception 'Only ACTIVE or SUSPENDED memberships can be exited.';
  end if;

  if exists (
    select 1 from public.membership_exits me
    where me.membership_id=target_membership_id and me.status<>'CANCELLED'
  ) then
    raise exception 'An active exit record already exists for this membership.';
  end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id and pay.status='APPROVED';

  calculated_refund:=case
    when target_refund_amount is null then contributed_amount
    else greatest(target_refund_amount,0)
  end;

  insert into public.membership_exits(
    membership_id,reason,exit_date,refund_policy,amount_contributed,refund_amount,status,notes
  )
  values(
    target_membership_id,exit_reason,target_exit_date,target_refund_policy,
    contributed_amount,calculated_refund,'PENDING',nullif(btrim(target_notes),'')
  )
  returning id into exit_id_value;

  perform public.transition_membership_status_for_admin(target_membership_id,'EXITED');

  return exit_id_value;
end;
$function$;

CREATE OR REPLACE FUNCTION public.approve_membership_exit_for_admin(target_exit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  target_org_id uuid;
  target_membership_id uuid;
  contributed_amount bigint:=0;
  existing_status public.settlement_status;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id,me.membership_id,me.status
    into target_org_id,target_membership_id,existing_status
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
  for update;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to approve this exit.'; end if;
  if existing_status<>'PENDING' then raise exception 'Exit is not pending approval.'; end if;

  select coalesce(sum(pa.amount),0) into contributed_amount
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id and pay.status='APPROVED';

  update public.membership_exits
  set amount_contributed=contributed_amount,
      refund_amount=case when coalesce(refund_amount,0)=0 then contributed_amount else least(refund_amount,contributed_amount) end,
      approved_by=(select id from public.users where id=auth.uid())
  where id=target_exit_id and status='PENDING';

  if not found then raise exception 'Exit is no longer pending.'; end if;

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'APPROVED');
end;
$function$;

CREATE OR REPLACE FUNCTION public.settle_membership_exit_for_admin(target_exit_id uuid, settlement_payment_method muppu_settlement_method DEFAULT 'PAID_IN_ADVANCE'::muppu_settlement_method, settlement_reference text DEFAULT NULL::text, settlement_date timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  target_org_id uuid;
  target_status public.settlement_status;
  target_policy public.refund_policy;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id,me.status,me.refund_policy
    into target_org_id,target_status,target_policy
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
  for update;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to settle this exit.'; end if;
  if target_status<>'APPROVED' then raise exception 'Exit must be approved before settlement.'; end if;
  if settlement_payment_method='PAID_IN_ADVANCE' then
    raise exception 'Use the refund payment action to record an immediate refund.';
  end if;
  if target_policy='IMMEDIATE' then
    raise exception 'Immediate refunds must be settled through the refund transaction action.';
  end if;

  update public.membership_exits
  set notes=concat_ws(' | ',notes,'Settled without immediate cash refund: ',coalesce(settlement_reference,''))
  where id=target_exit_id and status='APPROVED';

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');
end;
$function$;

CREATE OR REPLACE FUNCTION public.transition_membership_exit_status_for_admin(target_exit_id uuid, target_status settlement_status)
 RETURNS settlement_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_status public.settlement_status;
  org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;

  select me.status,k.organization_id
    into current_status,org_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
  for update;

  if org_id is null then raise exception 'Membership exit not found.'; end if;

  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to change this exit status.'; end if;

  if current_status=target_status then return current_status; end if;

  if not (
    (current_status='PENDING' and target_status in ('APPROVED','CANCELLED'))
    or (current_status='APPROVED' and target_status in ('SETTLED','CANCELLED'))
  ) then
    raise exception 'Invalid membership exit transition: % -> %.', current_status, target_status;
  end if;

  update public.membership_exits
  set status=target_status,
      settled_at=case when target_status='SETTLED' then coalesce(settled_at,now()) else settled_at end
  where id=target_exit_id;

  return target_status;
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_membership_exit_refund_for_admin(target_exit_id uuid, refund_amount bigint, refund_payment_method payment_method, refund_reference text DEFAULT NULL::text, refund_paid_at timestamp with time zone DEFAULT NULL::timestamp with time zone, refund_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  target_org_id uuid;
  expected_refund bigint;
  existing_paid bigint:=0;
  transaction_id uuid;
  target_membership_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if refund_amount<=0 then raise exception 'Refund amount must be greater than zero.'; end if;

  select k.organization_id,me.refund_amount,me.membership_id
    into target_org_id,expected_refund,target_membership_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
  for update;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to record this refund.'; end if;
  if not exists (
    select 1 from public.membership_exits me
    where me.id=target_exit_id and me.status='APPROVED' and me.refund_policy='IMMEDIATE'
  ) then raise exception 'Only approved immediate refunds can be paid here.'; end if;

  select coalesce(rt.amount,0) into existing_paid
  from public.membership_exit_refund_transactions rt
  where rt.membership_exit_id=target_exit_id
  for update;

  if existing_paid>0 then raise exception 'A refund transaction already exists for this exit.'; end if;
  if refund_amount>expected_refund then raise exception 'Refund exceeds the approved refund amount.'; end if;

  insert into public.membership_exit_refund_transactions(
    membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
  ) values (
    target_exit_id,refund_amount,refund_payment_method,nullif(btrim(refund_reference),''),
    coalesce(refund_paid_at,now()),(select id from public.users where id=auth.uid()),
    nullif(btrim(refund_notes),'')
  ) returning id into transaction_id;

  if refund_amount=expected_refund then
    perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');
  end if;

  return transaction_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_death_settlement_for_admin(target_exit_id uuid, target_nominee_id uuid DEFAULT NULL::uuid, settlement_notes text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org_id uuid;
  v_person_id uuid;
  v_refund_amount bigint:=0;
  v_status public.settlement_status;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id,m.person_id,coalesce(me.refund_amount,0),me.status
    into v_org_id,v_person_id,v_refund_amount,v_status
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id and me.reason='DEATH'
  for update;

  if v_org_id is null then raise exception 'Death exit record not found.'; end if;
  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to settle this death case.'; end if;
  if v_status<>'APPROVED' then raise exception 'Death exit must be approved before settlement.'; end if;
  if target_nominee_id is null then raise exception 'A nominee must be selected before settlement.'; end if;
  if not exists(select 1 from public.nominees n where n.id=target_nominee_id and n.person_id=v_person_id) then
    raise exception 'Selected nominee does not belong to this person.'; end if;
  if v_refund_amount>0 and exists(select 1 from public.membership_exit_refund_transactions rt where rt.membership_exit_id=target_exit_id) then
    raise exception 'A refund transaction already exists for this death exit.'; end if;

  if v_refund_amount>0 then
    insert into public.membership_exit_refund_transactions(
      membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
    ) values(
      target_exit_id,v_refund_amount,'OTHER',null,now(),
      (select id from public.users where id=auth.uid()),
      'Death settlement refund to nominee: ' ||
      coalesce((select n.name from public.nominees n where n.id=target_nominee_id),'Nominee')
    );
  end if;

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');

  update public.membership_exits
  set settled_to_nominee_id=target_nominee_id,
      settlement_notes=nullif(btrim(record_death_settlement_for_admin.settlement_notes),'')
  where id=target_exit_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_membership_exit_reconciliation_for_admin(target_exit_id uuid)
 RETURNS TABLE(exit_id uuid, membership_id uuid, kuri_id uuid, kuri_name text, membership_number text, registered_name text, display_name text, reason settlement_reason, refund_policy refund_policy, amount_contributed bigint, refund_amount bigint, exit_status settlement_status, paid_refund_amount bigint, refund_balance bigint, refund_payment_id uuid, refund_payment_method payment_method, refund_payment_reference text, refund_paid_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    me.id,
    m.id,
    k.id,
    k.name,
    m.membership_number,
    p.registered_name,
    p.display_name,
    me.reason,
    me.refund_policy,
    me.amount_contributed,
    me.refund_amount,
    me.status,
    coalesce(rt.amount,0),
    greatest(me.refund_amount-coalesce(rt.amount,0),0),
    rt.id,
    rt.payment_method,
    rt.payment_reference,
    rt.paid_at
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  join public.people p on p.id=m.person_id
  left join public.membership_exit_refund_transactions rt on rt.membership_exit_id=me.id
  where me.id=target_exit_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

CREATE OR REPLACE FUNCTION public.get_death_settlement_context_for_admin(target_membership_id uuid)
 RETURNS TABLE(membership_id uuid, membership_number text, person_id uuid, registered_name text, display_name text, nominee_id uuid, nominee_name text, nominee_relationship text, nominee_phone text, nominee_address text, nominee_notes text, refund_policy refund_policy, amount_contributed bigint, refund_amount bigint, exit_status settlement_status, exit_date date, settled_to_nominee_id uuid, settlement_notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
select
  m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
  n.id,n.name,n.relationship,n.phone,n.address,n.notes,
  me.refund_policy,me.amount_contributed,me.refund_amount,me.status,me.exit_date,
  me.settled_to_nominee_id,me.settlement_notes
from public.memberships m
join public.people p on p.id=m.person_id
join public.kuris k on k.id=m.kuri_id
join public.membership_exits me on me.membership_id=m.id
left join public.nominees n on n.person_id=m.person_id
  and (me.settled_to_nominee_id is null or n.id=me.settled_to_nominee_id)
where m.id=target_membership_id
  and me.reason='DEATH'
  and me.status<>'CANCELLED'
  and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
order by n.name,n.id;
$function$;

CREATE OR REPLACE FUNCTION public.list_membership_exits_for_admin(target_kuri_id uuid)
 RETURNS TABLE(exit_id uuid, membership_id uuid, membership_number text, registered_name text, display_name text, reason settlement_reason, exit_date date, refund_policy refund_policy, amount_contributed bigint, refund_amount bigint, status settlement_status, approved_by uuid, settled_at timestamp with time zone, notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    me.id,m.id,m.membership_number,p.registered_name,p.display_name,
    me.reason,me.exit_date,me.refund_policy,me.amount_contributed,
    me.refund_amount,me.status,me.approved_by,me.settled_at,me.notes
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.people p on p.id=m.person_id
  join public.kuris k on k.id=m.kuri_id
  where k.id=target_kuri_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by me.exit_date desc, m.membership_number;
$function$;

CREATE OR REPLACE FUNCTION public.refresh_membership_exit_financials_for_admin(target_exit_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare target_org_id uuid; target_membership_id uuid; contributed_amount bigint:=0;
begin
if auth.uid() is null then raise exception 'You must be signed in.'; end if;
select k.organization_id,me.membership_id into target_org_id,target_membership_id from public.membership_exits me join public.memberships m on m.id=me.membership_id join public.kuris k on k.id=m.kuri_id where me.id=target_exit_id;
if target_org_id is null then raise exception 'Exit record not found.'; end if;
if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to refresh this exit.'; end if;
select coalesce(sum(pa.amount),0) into contributed_amount from public.payment_allocations pa join public.payments pay on pay.id=pa.payment_id join public.installments i on i.id=pa.installment_id where i.membership_id=target_membership_id and pay.status='APPROVED' and pay.organization_id=target_org_id;
update public.membership_exits me set amount_contributed=contributed_amount,refund_amount=case when coalesce(me.refund_amount,0)=0 then contributed_amount else least(me.refund_amount,contributed_amount) end where me.id=target_exit_id; end $function$;

CREATE OR REPLACE FUNCTION public.get_membership_exit_membership_id_for_admin(target_exit_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select me.membership_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

CREATE OR REPLACE FUNCTION public.get_membership_nominees_for_admin(target_membership_id uuid)
 RETURNS TABLE(membership_id uuid, membership_number text, person_id uuid, registered_name text, display_name text, nominee_id uuid, nominee_name text, nominee_relationship text, nominee_phone text, nominee_address text, nominee_notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
select m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,n.id,n.name,n.relationship,n.phone,n.address,n.notes
from public.memberships m join public.people p on p.id=m.person_id join public.kuris k on k.id=m.kuri_id
left join public.nominees n on n.person_id=m.person_id
where m.id=target_membership_id and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
order by n.name,n.id;$function$;

CREATE OR REPLACE FUNCTION public.transition_membership_status_for_admin(target_membership_id uuid, target_status membership_status)
 RETURNS membership_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  current_status public.membership_status;
  org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;

  select m.status, k.organization_id
    into current_status, org_id
  from public.memberships m
  join public.kuris k on k.id=m.kuri_id
  where m.id=target_membership_id
  for update;

  if org_id is null then raise exception 'Membership not found.'; end if;

  if not public.has_kuri_admin_role((select m.kuri_id from public.memberships m where m.id=target_membership_id), array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to change this membership status.'; end if;

  if current_status=target_status then return current_status; end if;

  if not (
    (current_status='PENDING' and target_status='ACTIVE')
    or (current_status='ACTIVE' and target_status in ('SUSPENDED','EXITED','COMPLETED','TRANSFERRED'))
    or (current_status='SUSPENDED' and target_status in ('ACTIVE','EXITED','COMPLETED','TRANSFERRED'))
  ) then
    raise exception 'Invalid membership status transition: % -> %.', current_status, target_status;
  end if;

  update public.memberships
  set status=target_status,
      exited_at=case when target_status='EXITED' then coalesce(exited_at,now()) else exited_at end,
      completed_at=case when target_status='COMPLETED' then coalesce(completed_at,now()) else completed_at end
  where id=target_membership_id;

  return target_status;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_muppu_record_for_admin(target_kuri_id uuid, target_cycle_id uuid, target_person_id uuid, target_amount bigint)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_org_id uuid;
  v_person_org_id uuid;
  v_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  if target_amount < 0 then
    raise exception 'Muppu amount cannot be negative.';
  end if;

  select k.organization_id
    into v_org_id
  from public.kuris k
  join public.cycles c
    on c.kuri_id=k.id
   and c.id=target_cycle_id
  where k.id=target_kuri_id;

  if v_org_id is null then
    raise exception 'Kuri or cycle not found.';
  end if;

  if not public.has_kuri_admin_role(target_kuri_id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to manage Muppu.';
  end if;

  select p.organization_id
    into v_person_org_id
  from public.people p
  where p.id=target_person_id;

  if v_person_org_id is null then
    raise exception 'Person not found.';
  end if;

  if v_person_org_id<>v_org_id then
    raise exception 'Person does not belong to this organization.';
  end if;

  insert into public.muppu_records(kuri_id,cycle_id,person_id,amount,status)
  values(target_kuri_id,target_cycle_id,target_person_id,target_amount,'UNPAID')
  returning id into v_id;

  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_muppu_records_for_admin(target_kuri_id uuid DEFAULT NULL::uuid, target_cycle_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(muppu_id uuid, kuri_id uuid, kuri_name text, cycle_id uuid, cycle_number integer, person_id uuid, registered_name text, display_name text, amount bigint, status muppu_status, settlement_method muppu_settlement_method, paid_at timestamp with time zone, payment_reference text, created_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select mr.id,mr.kuri_id,k.name,mr.cycle_id,c.cycle_number,mr.person_id,p.registered_name,p.display_name,
         mr.amount,mr.status,mr.settlement_method,mr.paid_at,mr.payment_reference,mr.created_at
  from public.muppu_records mr
  join public.kuris k on k.id=mr.kuri_id
  join public.cycles c on c.id=mr.cycle_id
  join public.people p on p.id=mr.person_id
  where (target_kuri_id is null or mr.kuri_id=target_kuri_id)
    and (target_cycle_id is null or mr.cycle_id=target_cycle_id)
    and public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by c.cycle_number desc,p.display_name,p.registered_name;
$function$;

CREATE OR REPLACE FUNCTION public.mark_muppu_paid_for_admin(target_muppu_id uuid, paid_payment_reference text DEFAULT NULL::text, paid_at_value timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_org_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id into v_org_id
  from public.muppu_records mr join public.kuris k on k.id=mr.kuri_id
  where mr.id=target_muppu_id;

  if v_org_id is null then raise exception 'Muppu record not found.'; end if;

  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to manage Muppu.'; end if;

  update public.muppu_records mr
  set status='PAID',
      settlement_method='PAID_IN_ADVANCE',
      paid_at=coalesce(paid_at_value,now()),
      payment_reference=nullif(btrim(paid_payment_reference),'')
  where mr.id=target_muppu_id and mr.status='UNPAID';

  if not found then raise exception 'Only unpaid Muppu records can be marked paid.'; end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.waive_muppu_for_admin(target_muppu_id uuid, waiver_reference text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select k.organization_id into v_org_id from public.muppu_records mr join public.kuris k on k.id=mr.kuri_id where mr.id=target_muppu_id;
  if v_org_id is null then raise exception 'Muppu record not found.'; end if;
  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to manage Muppu.'; end if;
  update public.muppu_records mr
  set status='WAIVED',settlement_method='WAIVED',payment_reference=nullif(btrim(waiver_reference),'')
  where mr.id=target_muppu_id and mr.status='UNPAID';
  if not found then raise exception 'Only unpaid Muppu records can be waived.'; end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.deduct_muppu_from_prize_for_admin(target_muppu_id uuid, deduction_reference text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_org_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select k.organization_id into v_org_id from public.muppu_records mr join public.kuris k on k.id=mr.kuri_id where mr.id=target_muppu_id;
  if v_org_id is null then raise exception 'Muppu record not found.'; end if;
  if not public.has_kuri_admin_role(k.id, array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to manage Muppu.'; end if;
  update public.muppu_records mr
  set status='DEDUCTED',settlement_method='DEDUCTED_FROM_PRIZE',payment_reference=nullif(btrim(deduction_reference),'')
  where mr.id=target_muppu_id and mr.status='UNPAID';
  if not found then raise exception 'Only unpaid Muppu records can be deducted.'; end if;
end;
$function$;

commit;
