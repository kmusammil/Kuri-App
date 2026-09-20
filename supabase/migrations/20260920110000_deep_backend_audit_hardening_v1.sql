-- Deep backend audit hardening: restore RLS helper execution,
-- close internal RPC exposure, and enforce cross-domain lifecycle coupling.

begin;

-- These SECURITY DEFINER helpers are intentionally used by RLS policies.
-- They must remain executable by authenticated callers so policies can evaluate.
grant execute on function public.has_org_role(uuid, public.app_role[]) to authenticated;
grant execute on function public.is_org_member(uuid) to authenticated;

-- Test/reconciliation helpers are internal and must not be exposed through PostgREST.
revoke execute on function public.create_isolated_state_machine_test_kuri() from public, anon, authenticated;
revoke execute on function public.reconcile_installment_from_allocations(uuid) from public, anon, authenticated;

-- Generic membership/exit/payout transition helpers are implementation details.
-- Their domain-specific RPCs remain the public application API.
revoke execute on function public.transition_membership_status_for_admin(uuid, public.membership_status) from public, anon, authenticated;
revoke execute on function public.transition_membership_exit_status_for_admin(uuid, public.settlement_status) from public, anon, authenticated;
revoke execute on function public.transition_payout_status_for_admin(uuid, public.payout_status) from public, anon, authenticated;

-- Kuri/cycle/draw transitions are still used by the current dashboard.
-- Harden them below rather than removing their API surface.

create or replace function public.transition_kuri_status_for_admin(
  target_kuri_id uuid, target_status public.kuri_status
)
returns public.kuri_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_status public.kuri_status;
  org_id uuid;
  configured_cycles integer;
  actual_cycles integer;
  nonterminal_cycles integer;
begin
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  select k.status, k.organization_id, k.number_of_cycles
    into current_status, org_id, configured_cycles
  from public.kuris k
  where k.id = target_kuri_id
  for update;

  if org_id is null then
    raise exception 'Kuri not found.';
  end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id = org_id
      and ou.user_id = (select auth.uid())
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to change this Kuri status.';
  end if;

  if current_status = target_status then
    return current_status;
  end if;

  if not (
    (current_status='DRAFT' and target_status='OPEN')
    or (current_status='OPEN' and target_status='ACTIVE')
    or (current_status='ACTIVE' and target_status='COMPLETED')
    or (current_status='COMPLETED' and target_status='ARCHIVED')
  ) then
    raise exception 'Invalid Kuri status transition: % -> %.', current_status, target_status;
  end if;

  if current_status='ACTIVE' and target_status='COMPLETED' then
    select count(*) into actual_cycles
    from public.cycles c
    where c.kuri_id=target_kuri_id;

    select count(*) into nonterminal_cycles
    from public.cycles c
    where c.kuri_id=target_kuri_id
      and c.status not in ('COMPLETED','CANCELLED');

    if actual_cycles <> configured_cycles then
      raise exception 'Kuri cannot be completed until all configured cycles exist.';
    end if;

    if nonterminal_cycles > 0 then
      raise exception 'Kuri cannot be completed while cycles are not completed or cancelled.';
    end if;
  end if;

  update public.kuris
  set status=target_status, updated_at=now()
  where id=target_kuri_id;

  return target_status;
end;
$function$;

create or replace function public.transition_cycle_status_for_admin(
  target_cycle_id uuid, target_status public.cycle_status
)
returns public.cycle_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_status public.cycle_status;
  org_id uuid;
  kuri_id uuid;
  finalized_draw_count integer;
  winner_count integer;
begin
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  select c.status, c.kuri_id, k.organization_id
    into current_status, kuri_id, org_id
  from public.cycles c
  join public.kuris k on k.id=c.kuri_id
  where c.id=target_cycle_id
  for update;

  if org_id is null then
    raise exception 'Cycle not found.';
  end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=org_id
      and ou.user_id=(select auth.uid())
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to change this cycle status.';
  end if;

  if current_status=target_status then
    return current_status;
  end if;

  if not (
    (current_status='UPCOMING' and target_status='OPEN')
    or (current_status='OPEN' and target_status='PAYMENT_CLOSED')
    or (current_status='PAYMENT_CLOSED' and target_status='DRAW_PENDING')
    or (current_status='DRAW_PENDING' and target_status='COMPLETED')
    or (current_status in ('UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING') and target_status='CANCELLED')
  ) then
    raise exception 'Invalid cycle status transition: % -> %.', current_status, target_status;
  end if;

  if current_status='DRAW_PENDING' and target_status='COMPLETED' then
    select count(*) into finalized_draw_count
    from public.draw_sessions d
    where d.cycle_id=target_cycle_id
      and d.kuri_id=kuri_id
      and d.status='FINALIZED';

    select count(*) into winner_count
    from public.monthly_winners mw
    where mw.cycle_id=target_cycle_id;

    if finalized_draw_count <> 1 then
      raise exception 'Cycle cannot be completed until its draw is FINALIZED.';
    end if;

    if winner_count < 1 then
      raise exception 'Cycle cannot be completed without at least one finalized winner.';
    end if;
  end if;

  update public.cycles set status=target_status where id=target_cycle_id;
  return target_status;
end;
$function$;

create or replace function public.transition_draw_status_for_admin(
  target_draw_session_id uuid, target_status public.draw_status
)
returns public.draw_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
  current_status public.draw_status;
  org_id uuid;
  cycle_id uuid;
  included_count integer;
  selection_count integer;
  winner_count integer;
  cycle_status public.cycle_status;
begin
  if (select auth.uid()) is null then
    raise exception 'You must be signed in.';
  end if;

  select d.status,d.cycle_id,k.organization_id,c.status
    into current_status,cycle_id,org_id,cycle_status
  from public.draw_sessions d
  join public.kuris k on k.id=d.kuri_id
  join public.cycles c on c.id=d.cycle_id
  where d.id=target_draw_session_id
  for update;

  if org_id is null then
    raise exception 'Draw session not found.';
  end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=org_id
      and ou.user_id=(select auth.uid())
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to change this draw status.';
  end if;

  if current_status=target_status then
    return current_status;
  end if;

  if not (
    (current_status='DRAFT' and target_status='POOL_READY')
    or (current_status='POOL_READY' and target_status in ('DRAWING','CANCELLED'))
    or (current_status='DRAWING' and target_status in ('RESULTS_READY','CANCELLED'))
    or (current_status='RESULTS_READY' and target_status='FINALIZED')
  ) then
    raise exception 'Invalid draw status transition: % -> %.', current_status, target_status;
  end if;

  if target_status='POOL_READY' then
    select count(*) into included_count
    from public.draw_pool_entries e
    where e.draw_session_id=target_draw_session_id
      and e.admin_included;

    if included_count < 1 then
      raise exception 'Draw cannot become POOL_READY without an included pool entry.';
    end if;
  elsif target_status='DRAWING' then
    if cycle_status <> 'DRAW_PENDING' then
      raise exception 'Draw can only start while the cycle is DRAW_PENDING.';
    end if;

    select count(*) into included_count
    from public.draw_pool_entries e
    where e.draw_session_id=target_draw_session_id
      and e.admin_included;

    if included_count < 1 then
      raise exception 'Draw cannot start without an included pool.';
    end if;
  elsif target_status='RESULTS_READY' then
    select count(*) into selection_count
    from public.draw_selections s
    where s.draw_session_id=target_draw_session_id;

    if selection_count < 1 then
      raise exception 'Draw cannot become RESULTS_READY without selections.';
    end if;
  elsif target_status='FINALIZED' then
    if cycle_status <> 'DRAW_PENDING' then
      raise exception 'Draw cannot be finalized unless the cycle is DRAW_PENDING.';
    end if;

    select count(*) into selection_count
    from public.draw_selections s
    where s.draw_session_id=target_draw_session_id;

    select count(*) into winner_count
    from public.monthly_winners mw
    where mw.cycle_id=cycle_id;

    if selection_count < 1 then
      raise exception 'Draw cannot be finalized without selections.';
    end if;

    if winner_count < 1 then
      raise exception 'Draw cannot be finalized before at least one winner is finalized.';
    end if;
  end if;

  update public.draw_sessions
  set status=target_status,
      started_at=case when target_status='DRAWING' then coalesce(started_at,now()) else started_at end,
      completed_at=case when target_status in ('RESULTS_READY','FINALIZED','CANCELLED') then coalesce(completed_at,now()) else completed_at end
  where id=target_draw_session_id;

  return target_status;
end;
$function$;

-- Preserve the current dashboard API for these three transitions.
revoke all on function public.transition_kuri_status_for_admin(uuid,public.kuri_status) from public;
revoke all on function public.transition_cycle_status_for_admin(uuid,public.cycle_status) from public;
revoke all on function public.transition_draw_status_for_admin(uuid,public.draw_status) from public;
grant execute on function public.transition_kuri_status_for_admin(uuid,public.kuri_status) to authenticated;
grant execute on function public.transition_cycle_status_for_admin(uuid,public.cycle_status) to authenticated;
grant execute on function public.transition_draw_status_for_admin(uuid,public.draw_status) to authenticated;

commit;
