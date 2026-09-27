-- WINNER-006: finalized winner immutability

create or replace function public.enforce_finalized_winner_immutability()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $function$
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception 'Finalized winner records are immutable.';
  end if;
  return new;
end;
$function$;

drop trigger if exists monthly_winners_immutability on public.monthly_winners;
create trigger monthly_winners_immutability
before update or delete on public.monthly_winners
for each row execute function public.enforce_finalized_winner_immutability();

drop trigger if exists monthly_winner_memberships_immutability on public.monthly_winner_memberships;
create trigger monthly_winner_memberships_immutability
before update or delete on public.monthly_winner_memberships
for each row execute function public.enforce_finalized_winner_immutability();

revoke all on function public.enforce_finalized_winner_immutability() from public;
revoke all on function public.enforce_finalized_winner_immutability() from anon;
grant execute on function public.enforce_finalized_winner_immutability() to authenticated;
