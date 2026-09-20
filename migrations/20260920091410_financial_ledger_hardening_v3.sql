begin;

-- Prevent future payout records/status changes before the cycle is completed.
-- Existing historical/test rows are intentionally preserved.

create or replace function public.enforce_payout_cycle_completion()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  cycle_state public.cycle_status;
begin
  select c.status into cycle_state
  from public.monthly_winners mw
  join public.cycles c on c.id=mw.cycle_id
  where mw.id=new.monthly_winner_id;

  if cycle_state is null then
    raise exception 'Payout winner/cycle context not found.';
  end if;

  if cycle_state<>'COMPLETED' then
    raise exception 'Payouts can only be created or changed after the cycle is COMPLETED.';
  end if;

  return new;
end;
$$;

drop trigger if exists payouts_cycle_completion_guard on public.payouts;
create trigger payouts_cycle_completion_guard
before insert or update of monthly_winner_id,status on public.payouts
for each row execute function public.enforce_payout_cycle_completion();

revoke all on function public.enforce_payout_cycle_completion() from public;

commit;
