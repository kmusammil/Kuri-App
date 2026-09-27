-- MEMBERSHIP-005: prevent late-joined memberships from entering historical draw pools
-- A draw pool is a snapshot of memberships that existed when the draw was prepared.
-- A membership joined after the draw session began cannot be inserted into that pool.
-- Finalized/cancelled draw sessions are immutable for pool membership.

create or replace function public.enforce_draw_pool_membership_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  session_status public.draw_status;
  session_started_at timestamptz;
  membership_joined_at timestamptz;
begin
  select d.status,d.started_at
    into session_status,session_started_at
  from public.draw_sessions d
  where d.id=new.draw_session_id
  for share;

  if session_status is null then
    raise exception 'Draw session not found.';
  end if;

  if session_status in ('FINALIZED','CANCELLED') then
    raise exception 'Finalized or cancelled draw pools cannot be modified.';
  end if;

  select m.joined_at
    into membership_joined_at
  from public.memberships m
  where m.id=new.membership_id
  for share;

  if membership_joined_at is null then
    raise exception 'Membership not found.';
  end if;

  if membership_joined_at > session_started_at then
    raise exception 'A membership created after the draw session began cannot participate in that historical draw.';
  end if;

  return new;
end;
$function$;

drop trigger if exists draw_pool_membership_history_guard on public.draw_pool_entries;

create trigger draw_pool_membership_history_guard
before insert or update of draw_session_id,membership_id
on public.draw_pool_entries
for each row
execute function public.enforce_draw_pool_membership_history();

revoke all on function public.enforce_draw_pool_membership_history() from public,anon;
grant execute on function public.enforce_draw_pool_membership_history() to authenticated;
