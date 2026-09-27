-- DRAW-001: freeze eligibility snapshot at POOL_READY

create or replace function public.enforce_draw_pool_eligibility_freeze()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  session_status public.draw_status;
begin
  if new.system_eligible is distinct from old.system_eligible then
    select d.status
      into session_status
    from public.draw_sessions d
    where d.id = old.draw_session_id
    for update;

    if session_status = 'POOL_READY' then
      raise exception 'Draw eligibility is frozen once the pool reaches POOL_READY.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists draw_pool_eligibility_freeze on public.draw_pool_entries;

create trigger draw_pool_eligibility_freeze
before update of system_eligible on public.draw_pool_entries
for each row
execute function public.enforce_draw_pool_eligibility_freeze();

revoke all on function public.enforce_draw_pool_eligibility_freeze() from public;
revoke all on function public.enforce_draw_pool_eligibility_freeze() from anon;
grant execute on function public.enforce_draw_pool_eligibility_freeze() to authenticated;
