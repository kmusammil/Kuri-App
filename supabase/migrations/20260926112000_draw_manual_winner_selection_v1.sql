-- DRAW-002: record manual final winner selection correctly
--
-- finalize_draw_for_admin receives the administrator's explicit final
-- membership selection. The random draw produces suggestions/selections;
-- finalization is the manual decision and must be recorded as such.

create or replace function public.finalize_draw_for_admin(
  target_cycle_id uuid,
  final_membership_ids uuid[],
  p_idempotency_key text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_key text := nullif(btrim(p_idempotency_key),'');
  v_hash text;
  v_idem public.financial_idempotency_keys%rowtype;
  v_session_id uuid;
  v_kuri_id uuid;
  v_cycle_status public.cycle_status;
  v_draw_status public.draw_status;
  v_winner_count integer;
  v_selected_count integer;
  v_selected_person_count integer;
  v_unwon_member_count integer;
  v_remaining_cycles integer;
  v_max_winners integer;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if final_membership_ids is null or cardinality(final_membership_ids)<1 then
    raise exception 'Select at least one winner.';
  end if;
  if cardinality(final_membership_ids) <> cardinality(array(select distinct unnest(final_membership_ids))) then
    raise exception 'Duplicate winner memberships are not allowed.';
  end if;
  if v_key is null or char_length(v_key)>200 then
    raise exception 'A valid idempotency key is required.';
  end if;

  select c.kuri_id into v_kuri_id
  from public.cycles c
  where c.id=target_cycle_id
    and public.has_kuri_admin_role(c.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
  if v_kuri_id is null then raise exception 'You do not have permission to manage this draw.'; end if;

  v_hash:=encode(extensions.digest(
    jsonb_build_object('cycle_id',target_cycle_id::text,'membership_ids',to_jsonb(final_membership_ids))::text,
    'sha256'),'hex');

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'DRAW_FINALIZE',v_key,v_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into v_idem
  from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor
    and f.operation_type='DRAW_FINALIZE'
    and f.idempotency_key=v_key
  for update;

  if v_idem.request_hash<>v_hash then
    raise exception 'Idempotency key was already used for a different finalization request.';
  end if;
  if v_idem.status='COMPLETED' then
    select count(*) into v_winner_count from public.monthly_winners where cycle_id=target_cycle_id;
    return v_winner_count;
  end if;

  select d.id,c.kuri_id,c.status,d.status
    into v_session_id,v_kuri_id,v_cycle_status,v_draw_status
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  where d.cycle_id=target_cycle_id
    and public.has_kuri_admin_role(c.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update of d,c;

  if v_session_id is null then raise exception 'Prepare and run the draw before finalizing winners.'; end if;
  perform 1 from public.kuris k where k.id=v_kuri_id for update;

  if v_cycle_status<>'DRAW_PENDING' then raise exception 'Cycle must be DRAW_PENDING before finalizing winners.'; end if;
  if v_draw_status<>'RESULTS_READY' then raise exception 'Draw must have RESULTS_READY status before finalizing winners.'; end if;
  if exists(select 1 from public.monthly_winners where cycle_id=target_cycle_id) then
    raise exception 'Winners are already finalized for this cycle.';
  end if;

  select count(*) into v_selected_count
  from public.draw_selections s
  where s.draw_session_id=v_session_id
    and s.membership_id=any(final_membership_ids);
  if v_selected_count<>array_length(final_membership_ids,1) then
    raise exception 'Final winners must come from the current draw selections.';
  end if;

  if exists(
    select 1
    from public.memberships m
    join public.membership_exits me on me.membership_id=m.id
    where m.id=any(final_membership_ids)
      and me.reason='DEATH'
      and me.death_date_verified_at is not null
      and me.death_date<=current_date
      and me.status in ('PENDING','APPROVED')
  ) then
    raise exception 'A verified-deceased membership cannot be finalized as a winner.';
  end if;

  select count(distinct coalesce(m.current_holder_person_id,m.person_id))
    into v_selected_person_count
  from public.memberships m
  where m.id=any(final_membership_ids);
  if v_selected_person_count<>array_length(final_membership_ids,1) then
    raise exception 'Only one winner per current holder can be finalized in a cycle.';
  end if;

  if exists(
    select 1 from public.memberships m
    where m.id=any(final_membership_ids)
      and (m.kuri_id<>v_kuri_id or m.status<>'ACTIVE')
  ) then
    raise exception 'A final winner must be an ACTIVE membership in the draw Kuri.';
  end if;

  if exists(
    select 1
    from public.memberships m
    join public.monthly_winners mw on mw.person_id=coalesce(m.current_holder_person_id,m.person_id)
    join public.cycles wc on wc.id=mw.cycle_id
    where m.id=any(final_membership_ids)
      and wc.kuri_id=v_kuri_id
      and wc.id<>target_cycle_id
  ) then
    raise exception 'A current holder who has already won in this Kuri cannot win again.';
  end if;

  select count(distinct coalesce(m.current_holder_person_id,m.person_id))
    into v_unwon_member_count
  from public.memberships m
  where m.kuri_id=v_kuri_id
    and m.status='ACTIVE'
    and not exists(
      select 1
      from public.monthly_winners mw
      join public.cycles wc on wc.id=mw.cycle_id
      where wc.kuri_id=v_kuri_id
        and mw.person_id=coalesce(m.current_holder_person_id,m.person_id)
    );

  select greatest(k.number_of_cycles-c.cycle_number+1,0)
    into v_remaining_cycles
  from public.kuris k join public.cycles c on c.kuri_id=k.id
  where k.id=v_kuri_id and c.id=target_cycle_id;

  if v_remaining_cycles<1 then
    raise exception 'Unable to determine remaining cycles for winner finalization.';
  end if;
  if v_unwon_member_count<v_remaining_cycles then
    raise exception 'Insufficient remaining current holders for the remaining cycles; repeating winners is not allowed.';
  end if;

  v_max_winners:=v_unwon_member_count-(v_remaining_cycles-1);
  if array_length(final_membership_ids,1)>v_max_winners then
    raise exception 'Selected winner count exceeds the maximum feasible winner count of %.',v_max_winners;
  end if;

  insert into public.monthly_winners(
    cycle_id,person_id,selection_source,finalized_by,finalized_at
  )
  select
    target_cycle_id,
    coalesce(m.current_holder_person_id,m.person_id),
    'ADMIN_OVERRIDE'::public.winner_source,
    (select id from public.users where id=auth.uid()),
    now()
  from public.memberships m
  where m.id=any(final_membership_ids)
  group by coalesce(m.current_holder_person_id,m.person_id);

  insert into public.monthly_winner_memberships(monthly_winner_id,membership_id)
  select mw.id,m.id
  from public.monthly_winners mw
  join public.memberships m
    on coalesce(m.current_holder_person_id,m.person_id)=mw.person_id
  where mw.cycle_id=target_cycle_id
    and m.id=any(final_membership_ids);

  perform public.transition_draw_status_for_admin(v_session_id,'FINALIZED');
  perform public.transition_cycle_status_for_admin(target_cycle_id,'COMPLETED');

  select count(*) into v_winner_count
  from public.monthly_winners
  where cycle_id=target_cycle_id;

  update public.financial_idempotency_keys
  set status='COMPLETED',result_bigint=v_winner_count,completed_at=now()
  where id=v_idem.id;

  return v_winner_count;
end;
$function$;

revoke all on function public.finalize_draw_for_admin(uuid,uuid[],text) from public;
revoke all on function public.finalize_draw_for_admin(uuid,uuid[],text) from anon;
grant execute on function public.finalize_draw_for_admin(uuid,uuid[],text) to authenticated;
