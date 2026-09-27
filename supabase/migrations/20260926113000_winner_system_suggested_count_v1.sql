-- WINNER-002: expose system-suggested winner count

create or replace function public.suggest_winner_count_for_admin(
  target_cycle_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_kuri_id uuid;
  v_cycle_number integer;
  v_total_cycles integer;
  v_remaining_cycles integer;
  v_unwon_member_count integer;
  v_max_winners integer;
begin
  if v_actor is null then
    raise exception 'You must be signed in.';
  end if;

  select c.kuri_id, c.cycle_number, k.number_of_cycles
    into v_kuri_id, v_cycle_number, v_total_cycles
  from public.cycles c
  join public.kuris k on k.id = c.kuri_id
  where c.id = target_cycle_id
    and public.has_kuri_admin_role(
      c.kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );

  if v_kuri_id is null then
    raise exception 'You do not have permission to manage this draw.';
  end if;

  v_remaining_cycles := greatest(v_total_cycles - v_cycle_number + 1, 0);

  if v_remaining_cycles < 1 then
    raise exception 'Unable to determine remaining cycles for this draw.';
  end if;

  select count(distinct coalesce(m.current_holder_person_id, m.person_id))
    into v_unwon_member_count
  from public.memberships m
  where m.kuri_id = v_kuri_id
    and m.status = 'ACTIVE'
    and not exists (
      select 1
      from public.monthly_winners mw
      join public.cycles wc on wc.id = mw.cycle_id
      where wc.kuri_id = v_kuri_id
        and mw.person_id = coalesce(m.current_holder_person_id, m.person_id)
    );

  if v_unwon_member_count < v_remaining_cycles then
    raise exception
      'Insufficient remaining current holders for the remaining cycles; repeating winners is not allowed.';
  end if;

  v_max_winners := v_unwon_member_count - (v_remaining_cycles - 1);

  if v_max_winners < 1 then
    raise exception 'Unable to determine a valid suggested winner count.';
  end if;

  return v_max_winners;
end;
$function$;

revoke all on function public.suggest_winner_count_for_admin(uuid) from public;
revoke all on function public.suggest_winner_count_for_admin(uuid) from anon;
grant execute on function public.suggest_winner_count_for_admin(uuid) to authenticated;
