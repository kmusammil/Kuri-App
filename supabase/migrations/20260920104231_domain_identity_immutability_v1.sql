-- Deep backend audit hardening: make domain identity / tenant keys immutable
-- after creation so records cannot be moved across tenants or aggregates.

begin;

create or replace function public.enforce_domain_identity_immutability()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
begin
  if tg_table_name='kuris' then
    if new.organization_id is distinct from old.organization_id then
      raise exception 'Kuri organization cannot be changed after creation.';
    end if;
  elsif tg_table_name='people' then
    if new.organization_id is distinct from old.organization_id then
      raise exception 'Person organization cannot be changed after creation.';
    end if;
  elsif tg_table_name='payments' then
    if new.organization_id is distinct from old.organization_id
       or new.person_id is distinct from old.person_id then
      raise exception 'Payment organization and person cannot be changed after creation.';
    end if;
  elsif tg_table_name='cycles' then
    if new.kuri_id is distinct from old.kuri_id then
      raise exception 'Cycle Kuri cannot be changed after creation.';
    end if;
  elsif tg_table_name='memberships' then
    if new.kuri_id is distinct from old.kuri_id
       or new.person_id is distinct from old.person_id then
      raise exception 'Membership Kuri and person cannot be changed after creation.';
    end if;
  elsif tg_table_name='installments' then
    if new.membership_id is distinct from old.membership_id
       or new.cycle_id is distinct from old.cycle_id then
      raise exception 'Installment membership and cycle cannot be changed after creation.';
    end if;
  elsif tg_table_name='payment_allocations' then
    if new.payment_id is distinct from old.payment_id
       or new.installment_id is distinct from old.installment_id then
      raise exception 'Payment allocation payment and installment cannot be changed after creation.';
    end if;
  elsif tg_table_name='draw_sessions' then
    if new.kuri_id is distinct from old.kuri_id
       or new.cycle_id is distinct from old.cycle_id then
      raise exception 'Draw session Kuri and cycle cannot be changed after creation.';
    end if;
  elsif tg_table_name='draw_pool_entries' then
    if new.draw_session_id is distinct from old.draw_session_id
       or new.membership_id is distinct from old.membership_id then
      raise exception 'Draw pool entry draw and membership cannot be changed after creation.';
    end if;
  elsif tg_table_name='draw_selections' then
    if new.draw_session_id is distinct from old.draw_session_id
       or new.membership_id is distinct from old.membership_id then
      raise exception 'Draw selection draw and membership cannot be changed after creation.';
    end if;
  elsif tg_table_name='monthly_winners' then
    if new.cycle_id is distinct from old.cycle_id
       or new.person_id is distinct from old.person_id then
      raise exception 'Monthly winner cycle and person cannot be changed after creation.';
    end if;
  elsif tg_table_name='monthly_winner_memberships' then
    if new.monthly_winner_id is distinct from old.monthly_winner_id
       or new.membership_id is distinct from old.membership_id then
      raise exception 'Winner membership links cannot be reassigned.';
    end if;
  elsif tg_table_name='payouts' then
    if new.monthly_winner_id is distinct from old.monthly_winner_id then
      raise exception 'Payout winner cannot be changed after creation.';
    end if;
  elsif tg_table_name='muppu_records' then
    if new.kuri_id is distinct from old.kuri_id
       or new.cycle_id is distinct from old.cycle_id
       or new.person_id is distinct from old.person_id then
      raise exception 'Muppu Kuri, cycle and person cannot be changed after creation.';
    end if;
  elsif tg_table_name='membership_exits' then
    if new.membership_id is distinct from old.membership_id then
      raise exception 'Membership exit membership cannot be changed after creation.';
    end if;
  elsif tg_table_name='membership_exit_refund_transactions' then
    if new.membership_exit_id is distinct from old.membership_exit_id then
      raise exception 'Refund transaction exit cannot be changed after creation.';
    end if;
  end if;

  return new;
end;
$function$;

revoke all on function public.enforce_domain_identity_immutability() from public,anon,authenticated;

drop trigger if exists kuris_identity_immutability on public.kuris;
create trigger kuris_identity_immutability
before update of organization_id on public.kuris
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists people_identity_immutability on public.people;
create trigger people_identity_immutability
before update of organization_id on public.people
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists payments_identity_immutability on public.payments;
create trigger payments_identity_immutability
before update of organization_id,person_id on public.payments
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists cycles_identity_immutability on public.cycles;
create trigger cycles_identity_immutability
before update of kuri_id on public.cycles
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists memberships_identity_immutability on public.memberships;
create trigger memberships_identity_immutability
before update of kuri_id,person_id on public.memberships
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists installments_identity_immutability on public.installments;
create trigger installments_identity_immutability
before update of membership_id,cycle_id on public.installments
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists payment_allocations_identity_immutability on public.payment_allocations;
create trigger payment_allocations_identity_immutability
before update of payment_id,installment_id on public.payment_allocations
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists draw_sessions_identity_immutability on public.draw_sessions;
create trigger draw_sessions_identity_immutability
before update of kuri_id,cycle_id on public.draw_sessions
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists draw_pool_entries_identity_immutability on public.draw_pool_entries;
create trigger draw_pool_entries_identity_immutability
before update of draw_session_id,membership_id on public.draw_pool_entries
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists draw_selections_identity_immutability on public.draw_selections;
create trigger draw_selections_identity_immutability
before update of draw_session_id,membership_id on public.draw_selections
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists monthly_winners_identity_immutability on public.monthly_winners;
create trigger monthly_winners_identity_immutability
before update of cycle_id,person_id on public.monthly_winners
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists monthly_winner_memberships_identity_immutability on public.monthly_winner_memberships;
create trigger monthly_winner_memberships_identity_immutability
before update of monthly_winner_id,membership_id on public.monthly_winner_memberships
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists payouts_identity_immutability on public.payouts;
create trigger payouts_identity_immutability
before update of monthly_winner_id on public.payouts
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists muppu_records_identity_immutability on public.muppu_records;
create trigger muppu_records_identity_immutability
before update of kuri_id,cycle_id,person_id on public.muppu_records
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists membership_exits_identity_immutability on public.membership_exits;
create trigger membership_exits_identity_immutability
before update of membership_id on public.membership_exits
for each row execute function public.enforce_domain_identity_immutability();

drop trigger if exists membership_exit_refunds_identity_immutability on public.membership_exit_refund_transactions;
create trigger membership_exit_refunds_identity_immutability
before update of membership_exit_id on public.membership_exit_refund_transactions
for each row execute function public.enforce_domain_identity_immutability();

commit;