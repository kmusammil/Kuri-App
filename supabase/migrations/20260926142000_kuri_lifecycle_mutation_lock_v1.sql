-- KURI-LIFE-006: lifecycle-based locking of core Kuri configuration

create or replace function public.enforce_kuri_lifecycle_mutation_lock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if old.status in ('ACTIVE','COMPLETED','ARCHIVED') then
    if new.organization_id is distinct from old.organization_id
      or new.name is distinct from old.name
      or new.description is distinct from old.description
      or new.start_date is distinct from old.start_date
      or new.number_of_cycles is distinct from old.number_of_cycles
      or new.membership_limit is distinct from old.membership_limit
      or new.installment_amount is distinct from old.installment_amount
      or new.frequency is distinct from old.frequency
      or new.due_day is distinct from old.due_day
      or new.draw_day is distinct from old.draw_day
      or new.gross_prize_amount is distinct from old.gross_prize_amount
      or new.muppu_amount is distinct from old.muppu_amount
      or new.draw_eligibility_rule is distinct from old.draw_eligibility_rule
      or new.winner_rule is distinct from old.winner_rule
      or new.exit_refund_rule is distinct from old.exit_refund_rule
      or new.schedule_mode is distinct from old.schedule_mode
    then
      raise exception 'Core Kuri configuration cannot be changed after the Kuri becomes ACTIVE.';
    end if;
  end if;

  if old.status in ('COMPLETED','ARCHIVED') then
    if new.enrollment_closed_at is distinct from old.enrollment_closed_at
      or new.actual_started_at is distinct from old.actual_started_at
    then
      raise exception 'Completed or archived Kuri lifecycle timestamps are immutable.';
    end if;
  end if;

  if old.status='ARCHIVED' then
    if new.completed_at is distinct from old.completed_at
      or new.archived_at is distinct from old.archived_at
    then
      raise exception 'Archived Kuri lifecycle timestamps are immutable.';
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists kuri_lifecycle_mutation_lock on public.kuris;

create trigger kuri_lifecycle_mutation_lock
before update on public.kuris
for each row
execute function public.enforce_kuri_lifecycle_mutation_lock();

revoke all on function public.enforce_kuri_lifecycle_mutation_lock() from public,anon;
grant execute on function public.enforce_kuri_lifecycle_mutation_lock() to authenticated;
