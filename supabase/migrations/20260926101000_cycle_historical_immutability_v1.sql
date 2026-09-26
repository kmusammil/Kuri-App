-- CYCLE-009: Historical/finalized cycle immutability
-- Preserve lifecycle transitions, but freeze cycle data once the cycle is no longer UPCOMING.

create or replace function public.enforce_cycle_historical_immutability()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception 'Cycles cannot be deleted. Historical cycle records are immutable.';
  end if;

  if old.status in ('COMPLETED','CANCELLED') then
    raise exception 'Finalized or cancelled cycles are immutable.';
  end if;

  if old.status <> 'UPCOMING' then
    if new.id is distinct from old.id
       or new.kuri_id is distinct from old.kuri_id
       or new.cycle_number is distinct from old.cycle_number
       or new.period_start is distinct from old.period_start
       or new.period_end is distinct from old.period_end
       or new.due_date is distinct from old.due_date
       or new.draw_date is distinct from old.draw_date
       or new.created_at is distinct from old.created_at then
      raise exception 'Historical cycle data is immutable after the cycle leaves UPCOMING.';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists cycles_historical_immutability on public.cycles;

create trigger cycles_historical_immutability
before update or delete on public.cycles
for each row
execute function public.enforce_cycle_historical_immutability();

revoke all on function public.enforce_cycle_historical_immutability() from public, anon;
grant execute on function public.enforce_cycle_historical_immutability() to authenticated;