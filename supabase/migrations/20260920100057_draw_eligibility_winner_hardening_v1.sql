begin;

create or replace function public.enforce_draw_domain_integrity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  draw_kuri_id uuid;
  draw_cycle_id uuid;
  membership_kuri_id uuid;
  membership_status public.membership_status;
  cycle_status_value public.cycle_status;
  draw_status_value public.draw_status;
begin
  if tg_table_name = 'draw_pool_entries' then
    select d.kuri_id,d.cycle_id,d.status
      into draw_kuri_id,draw_cycle_id,draw_status_value
    from public.draw_sessions d
    where d.id = new.draw_session_id;

    select m.kuri_id,m.status
      into membership_kuri_id,membership_status
    from public.memberships m
    where m.id = new.membership_id;

    if draw_kuri_id is null or draw_cycle_id is null then
      raise exception 'Draw pool entry references an invalid draw session.';
    end if;
    if membership_kuri_id is null then
      raise exception 'Draw pool entry references an invalid membership.';
    end if;
    if membership_kuri_id <> draw_kuri_id then
      raise exception 'Draw pool membership must belong to the draw Kuri.';
    end if;
    if draw_status_value not in ('DRAFT','POOL_READY') then
      raise exception 'Draw pool can only be created or changed before the draw starts.';
    end if;

    if new.admin_included and not new.system_eligible and not new.override then
      raise exception 'A system-ineligible membership requires an explicit override.';
    end if;
    if new.override and nullif(btrim(new.override_reason),'') is null then
      raise exception 'An override requires a reason.';
    end if;
    if not new.override and new.admin_included <> new.system_eligible then
      raise exception 'Pool inclusion must match system eligibility unless override is true.';
    end if;
    if membership_status <> 'ACTIVE' and new.admin_included then
      raise exception 'Only ACTIVE memberships may be included in the draw pool.';
    end if;

  elsif tg_table_name = 'draw_selections' then
    select d.kuri_id,d.cycle_id,d.status
      into draw_kuri_id,draw_cycle_id,draw_status_value
    from public.draw_sessions d
    where d.id = new.draw_session_id;

    select m.kuri_id,m.status
      into membership_kuri_id,membership_status
    from public.memberships m
    where m.id = new.membership_id;

    if draw_kuri_id is null or draw_cycle_id is null then
      raise exception 'Draw selection references an invalid draw session.';
    end if;
    if membership_kuri_id is null or membership_kuri_id <> draw_kuri_id then
      raise exception 'Draw selection membership must belong to the draw Kuri.';
    end if;
    if membership_status <> 'ACTIVE' then
      raise exception 'Only ACTIVE memberships may be selected.';
    end if;
    if draw_status_value not in ('DRAWING','RESULTS_READY') then
      raise exception 'Selections can only exist while a draw is running or has results.';
    end if;
    if not exists (
      select 1 from public.draw_pool_entries e
      where e.draw_session_id = new.draw_session_id
        and e.membership_id = new.membership_id
        and e.admin_included
    ) then
      raise exception 'A draw selection must come from an included draw-pool entry.';
    end if;

  elsif tg_table_name = 'monthly_winners' then
    select c.kuri_id,c.status
      into draw_kuri_id,cycle_status_value
    from public.cycles c
    where c.id = new.cycle_id;

    if draw_kuri_id is null then
      raise exception 'Winner references an invalid cycle.';
    end if;
    if cycle_status_value <> 'DRAW_PENDING' then
      raise exception 'Winners can only be created while the cycle is DRAW_PENDING.';
    end if;
    if not exists (
      select 1
      from public.draw_sessions d
      where d.cycle_id = new.cycle_id
        and d.kuri_id = draw_kuri_id
        and d.status = 'RESULTS_READY'
    ) then
      raise exception 'Winners require a RESULTS_READY draw for the cycle.';
    end if;
    if not exists (
      select 1 from public.memberships m
      where m.person_id = new.person_id
        and m.kuri_id = draw_kuri_id
    ) then
      raise exception 'Winner person must have a membership in the cycle Kuri.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists draw_pool_domain_integrity on public.draw_pool_entries;
create trigger draw_pool_domain_integrity
before insert or update on public.draw_pool_entries
for each row execute function public.enforce_draw_domain_integrity();

drop trigger if exists draw_selection_domain_integrity on public.draw_selections;
create trigger draw_selection_domain_integrity
before insert or update on public.draw_selections
for each row execute function public.enforce_draw_domain_integrity();

drop trigger if exists monthly_winner_domain_integrity on public.monthly_winners;
create trigger monthly_winner_domain_integrity
before insert or update on public.monthly_winners
for each row execute function public.enforce_draw_domain_integrity();

revoke all on table public.draw_sessions from anon, authenticated;
revoke all on table public.draw_pool_entries from anon, authenticated;
revoke all on table public.draw_selections from anon, authenticated;
revoke all on table public.monthly_winners from anon, authenticated;
revoke all on table public.monthly_winner_memberships from anon, authenticated;

revoke all on function public.enforce_draw_domain_integrity() from public;
revoke all on function public.enforce_draw_status_transition() from public;

create index if not exists draw_pool_membership_idx
  on public.draw_pool_entries(membership_id);
create index if not exists draw_selections_membership_idx
  on public.draw_selections(membership_id);
create index if not exists monthly_winner_memberships_membership_idx
  on public.monthly_winner_memberships(membership_id);
create index if not exists monthly_winners_person_idx
  on public.monthly_winners(person_id);

commit;
