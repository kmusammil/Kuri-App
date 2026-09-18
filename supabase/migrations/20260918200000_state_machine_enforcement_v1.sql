begin;

-- Kuri-App backend state machine enforcement v1.
-- Adds guarded admin transition RPCs and database triggers for lifecycle status changes.
-- Existing rows/statuses are preserved; future status changes must follow legal transitions.

create or replace function public.transition_kuri_status_for_admin(
  target_kuri_id uuid,
  target_status public.kuri_status
) returns public.kuri_status
language plpgsql
security definer
set search_path = ''
as $$
declare current_status public.kuri_status; org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
  select k.status,k.organization_id into current_status,org_id from public.kuris k where k.id=target_kuri_id for update;
  if org_id is null then raise exception 'Kuri not found.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=org_id and ou.user_id=(select auth.uid()) and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to change this Kuri status.'; end if;
  if current_status=target_status then return current_status; end if;
  if not ((current_status='DRAFT' and target_status='OPEN') or (current_status='OPEN' and target_status='ACTIVE') or (current_status='ACTIVE' and target_status='COMPLETED') or (current_status='COMPLETED' and target_status='ARCHIVED')) then raise exception 'Invalid Kuri status transition: % -> %.',current_status,target_status; end if;
  update public.kuris set status=target_status,updated_at=now() where id=target_kuri_id;
  return target_status;
end $$;

create or replace function public.transition_membership_status_for_admin(
  target_membership_id uuid,
  target_status public.membership_status
) returns public.membership_status
language plpgsql
security definer
set search_path = ''
as $$
declare current_status public.membership_status; org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
  select m.status,k.organization_id into current_status,org_id from public.memberships m join public.kuris k on k.id=m.kuri_id where m.id=target_membership_id for update;
  if org_id is null then raise exception 'Membership not found.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=org_id and ou.user_id=(select auth.uid()) and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to change this membership status.'; end if;
  if current_status=target_status then return current_status; end if;
  if not ((current_status='PENDING' and target_status='ACTIVE') or (current_status='ACTIVE' and target_status in ('SUSPENDED','EXITED','COMPLETED','TRANSFERRED')) or (current_status='SUSPENDED' and target_status in ('ACTIVE','EXITED','COMPLETED','TRANSFERRED'))) then raise exception 'Invalid membership status transition: % -> %.',current_status,target_status; end if;
  update public.memberships set status=target_status,exited_at=case when target_status='EXITED' then coalesce(exited_at,now()) else exited_at end,completed_at=case when target_status='COMPLETED' then coalesce(completed_at,now()) else completed_at end where id=target_membership_id;
  return target_status;
end $$;

create or replace function public.transition_cycle_status_for_admin(
  target_cycle_id uuid,
  target_status public.cycle_status
) returns public.cycle_status
language plpgsql
security definer
set search_path = ''
as $$
declare current_status public.cycle_status; org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
  select c.status,k.organization_id into current_status,org_id from public.cycles c join public.kuris k on k.id=c.kuri_id where c.id=target_cycle_id for update;
  if org_id is null then raise exception 'Cycle not found.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=org_id and ou.user_id=(select auth.uid()) and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to change this cycle status.'; end if;
  if current_status=target_status then return current_status; end if;
  if not ((current_status='UPCOMING' and target_status='OPEN') or (current_status='OPEN' and target_status='PAYMENT_CLOSED') or (current_status='PAYMENT_CLOSED' and target_status='DRAW_PENDING') or (current_status='DRAW_PENDING' and target_status='COMPLETED') or (current_status in ('UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING') and target_status='CANCELLED')) then raise exception 'Invalid cycle status transition: % -> %.',current_status,target_status; end if;
  update public.cycles set status=target_status where id=target_cycle_id;
  return target_status;
end $$;

create or replace function public.transition_draw_status_for_admin(
  target_draw_session_id uuid,
  target_status public.draw_status
) returns public.draw_status
language plpgsql
security definer
set search_path = ''
as $$
declare current_status public.draw_status; org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
  select d.status,k.organization_id into current_status,org_id from public.draw_sessions d join public.kuris k on k.id=d.kuri_id where d.id=target_draw_session_id for update;
  if org_id is null then raise exception 'Draw session not found.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=org_id and ou.user_id=(select auth.uid()) and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to change this draw status.'; end if;
  if current_status=target_status then return current_status; end if;
  if not ((current_status='DRAFT' and target_status='POOL_READY') or (current_status='POOL_READY' and target_status in ('DRAWING','CANCELLED')) or (current_status='DRAWING' and target_status in ('RESULTS_READY','CANCELLED')) or (current_status='RESULTS_READY' and target_status='FINALIZED')) then raise exception 'Invalid draw status transition: % -> %.',current_status,target_status; end if;
  update public.draw_sessions set status=target_status,started_at=case when target_status='DRAWING' then coalesce(started_at,now()) else started_at end,completed_at=case when target_status in ('RESULTS_READY','FINALIZED','CANCELLED') then coalesce(completed_at,now()) else completed_at end where id=target_draw_session_id;
  return target_status;
end $$;

create or replace function public.transition_payout_status_for_admin(
  target_payout_id uuid,
  target_status public.payout_status
) returns public.payout_status
language plpgsql
security definer
set search_path = ''
as $$
declare current_status public.payout_status; org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
  select p.status,k.organization_id into current_status,org_id from public.payouts p join public.monthly_winners mw on mw.id=p.monthly_winner_id join public.cycles c on c.id=mw.cycle_id join public.kuris k on k.id=c.kuri_id where p.id=target_payout_id for update;
  if org_id is null then raise exception 'Payout not found.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=org_id and ou.user_id=(select auth.uid()) and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to change this payout status.'; end if;
  if current_status=target_status then return current_status; end if;
  if not ((current_status='PENDING' and target_status in ('PROCESSING','CANCELLED')) or (current_status='PROCESSING' and target_status in ('PAID','CANCELLED'))) then raise exception 'Invalid payout status transition: % -> %.',current_status,target_status; end if;
  update public.payouts set status=target_status where id=target_payout_id;
  return target_status;
end $$;

create or replace function public.transition_membership_exit_status_for_admin(
  target_exit_id uuid,
  target_status public.settlement_status
) returns public.settlement_status
language plpgsql
security definer
set search_path = ''
as $$
declare current_status public.settlement_status; org_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'You must be signed in.'; end if;
  select me.status,k.organization_id into current_status,org_id from public.membership_exits me join public.memberships m on m.id=me.membership_id join public.kuris k on k.id=m.kuri_id where me.id=target_exit_id for update;
  if org_id is null then raise exception 'Membership exit not found.'; end if;
  if not exists (select 1 from public.organization_users ou where ou.organization_id=org_id and ou.user_id=(select auth.uid()) and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then raise exception 'You do not have permission to change this exit status.'; end if;
  if current_status=target_status then return current_status; end if;
  if not ((current_status='PENDING' and target_status in ('APPROVED','CANCELLED')) or (current_status='APPROVED' and target_status in ('SETTLED','CANCELLED'))) then raise exception 'Invalid membership exit transition: % -> %.',current_status,target_status; end if;
  update public.membership_exits set status=target_status,settled_at=case when target_status='SETTLED' then coalesce(settled_at,now()) else settled_at end where id=target_exit_id;
  return target_status;
end $$;

create or replace function public.enforce_kuri_status_transition()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status<>old.status and not ((old.status='DRAFT' and new.status='OPEN') or (old.status='OPEN' and new.status='ACTIVE') or (old.status='ACTIVE' and new.status='COMPLETED') or (old.status='COMPLETED' and new.status='ARCHIVED')) then
    raise exception 'Invalid Kuri status transition: % -> %.',old.status,new.status;
  end if;
  return new;
end $$;

create or replace function public.enforce_membership_status_transition()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status<>old.status and not ((old.status='PENDING' and new.status='ACTIVE') or (old.status='ACTIVE' and new.status in ('SUSPENDED','EXITED','COMPLETED','TRANSFERRED')) or (old.status='SUSPENDED' and new.status in ('ACTIVE','EXITED','COMPLETED','TRANSFERRED'))) then
    raise exception 'Invalid membership status transition: % -> %.',old.status,new.status;
  end if;
  return new;
end $$;

create or replace function public.enforce_cycle_status_transition()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status<>old.status and not ((old.status='UPCOMING' and new.status='OPEN') or (old.status='OPEN' and new.status='PAYMENT_CLOSED') or (old.status='PAYMENT_CLOSED' and new.status='DRAW_PENDING') or (old.status='DRAW_PENDING' and new.status='COMPLETED') or (old.status in ('UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING') and new.status='CANCELLED')) then
    raise exception 'Invalid cycle status transition: % -> %.',old.status,new.status;
  end if;
  return new;
end $$;

create or replace function public.enforce_draw_status_transition()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status<>old.status and not ((old.status='DRAFT' and new.status='POOL_READY') or (old.status='POOL_READY' and new.status in ('DRAWING','CANCELLED')) or (old.status='DRAWING' and new.status in ('RESULTS_READY','CANCELLED')) or (old.status='RESULTS_READY' and new.status='FINALIZED')) then
    raise exception 'Invalid draw status transition: % -> %.',old.status,new.status;
  end if;
  return new;
end $$;

create or replace function public.enforce_payout_status_transition()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status<>old.status and not ((old.status='PENDING' and new.status in ('PROCESSING','CANCELLED')) or (old.status='PROCESSING' and new.status in ('PAID','CANCELLED'))) then
    raise exception 'Invalid payout status transition: % -> %.',old.status,new.status;
  end if;
  return new;
end $$;

create or replace function public.enforce_membership_exit_status_transition()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status<>old.status and not ((old.status='PENDING' and new.status in ('APPROVED','CANCELLED')) or (old.status='APPROVED' and new.status in ('SETTLED','CANCELLED'))) then
    raise exception 'Invalid membership exit transition: % -> %.',old.status,new.status;
  end if;
  return new;
end $$;

drop trigger if exists enforce_kuri_status_transition on public.kuris;
create trigger enforce_kuri_status_transition before update of status on public.kuris for each row execute function public.enforce_kuri_status_transition();

drop trigger if exists enforce_membership_status_transition on public.memberships;
create trigger enforce_membership_status_transition before update of status on public.memberships for each row execute function public.enforce_membership_status_transition();

drop trigger if exists enforce_cycle_status_transition on public.cycles;
create trigger enforce_cycle_status_transition before update of status on public.cycles for each row execute function public.enforce_cycle_status_transition();

drop trigger if exists enforce_draw_status_transition on public.draw_sessions;
create trigger enforce_draw_status_transition before update of status on public.draw_sessions for each row execute function public.enforce_draw_status_transition();

drop trigger if exists enforce_payout_status_transition on public.payouts;
create trigger enforce_payout_status_transition before update of status on public.payouts for each row execute function public.enforce_payout_status_transition();

drop trigger if exists enforce_membership_exit_status_transition on public.membership_exits;
create trigger enforce_membership_exit_status_transition before update of status on public.membership_exits for each row execute function public.enforce_membership_exit_status_transition();

revoke all on function public.transition_kuri_status_for_admin(uuid,public.kuri_status) from public;
revoke all on function public.transition_membership_status_for_admin(uuid,public.membership_status) from public;
revoke all on function public.transition_cycle_status_for_admin(uuid,public.cycle_status) from public;
revoke all on function public.transition_draw_status_for_admin(uuid,public.draw_status) from public;
revoke all on function public.transition_payout_status_for_admin(uuid,public.payout_status) from public;
revoke all on function public.transition_membership_exit_status_for_admin(uuid,public.settlement_status) from public;
grant execute on function public.transition_kuri_status_for_admin(uuid,public.kuri_status) to authenticated;
grant execute on function public.transition_membership_status_for_admin(uuid,public.membership_status) to authenticated;
grant execute on function public.transition_cycle_status_for_admin(uuid,public.cycle_status) to authenticated;
grant execute on function public.transition_draw_status_for_admin(uuid,public.draw_status) to authenticated;
grant execute on function public.transition_payout_status_for_admin(uuid,public.payout_status) to authenticated;
grant execute on function public.transition_membership_exit_status_for_admin(uuid,public.settlement_status) to authenticated;

commit;
