-- CYCLE-002: flexible cycle scheduling, planned dates and controlled overrides
-- Adds an explicit, audited mechanism for administrators to override the planned
-- schedule of a future cycle without changing its lifecycle status.

create table if not exists public.cycle_schedule_overrides (
  id uuid primary key default gen_random_uuid(),
  cycle_id uuid not null references public.cycles(id) on delete restrict,
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  previous_period_start date not null,
  previous_period_end date not null,
  previous_due_date date not null,
  previous_draw_date date not null,
  new_period_start date not null,
  new_period_end date not null,
  new_due_date date not null,
  new_draw_date date not null,
  reason text not null,
  changed_by uuid not null references public.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists cycle_schedule_overrides_cycle_created_idx
  on public.cycle_schedule_overrides(cycle_id, created_at desc);

alter table public.cycle_schedule_overrides enable row level security;

create or replace function public.override_future_cycle_schedule_for_admin(
  target_cycle_id uuid,
  new_period_start date,
  new_period_end date,
  new_due_date date,
  new_draw_date date,
  reason_text text
)
returns public.cycles
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_cycle public.cycles%rowtype;
  v_prev public.cycles%rowtype;
begin
  if v_actor is null then
    raise exception 'You must be signed in.';
  end if;

  if nullif(btrim(reason_text), '') is null then
    raise exception 'A reason is required for a cycle schedule override.';
  end if;

  if new_period_start is null
     or new_period_end is null
     or new_due_date is null
     or new_draw_date is null then
    raise exception 'All cycle schedule dates are required.';
  end if;

  if new_period_start > new_period_end then
    raise exception 'Cycle period start cannot be after period end.';
  end if;

  if new_due_date < new_period_start or new_due_date > new_period_end then
    raise exception 'Due date must fall within the cycle period.';
  end if;

  if new_draw_date < new_period_start or new_draw_date > new_period_end then
    raise exception 'Draw date must fall within the cycle period.';
  end if;

  select c.*
    into v_cycle
  from public.cycles c
  where c.id = target_cycle_id
    and public.has_kuri_admin_role(
      c.kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  for update;

  if v_cycle.id is null then
    raise exception 'You do not have permission to manage this cycle.';
  end if;

  if v_cycle.status <> 'UPCOMING' then
    raise exception 'Only UPCOMING cycles can have their planned schedule overridden.';
  end if;

  if new_period_start < current_date then
    raise exception 'A future cycle schedule cannot start in the past.';
  end if;

  select c.*
    into v_prev
  from public.cycles c
  where c.kuri_id = v_cycle.kuri_id
    and c.cycle_number = v_cycle.cycle_number - 1
    and c.status <> 'CANCELLED'
  limit 1;

  if v_prev.id is not null and new_period_start <= v_prev.period_end then
    raise exception 'Cycle period overlaps the previous cycle.';
  end if;

  if exists (
    select 1
    from public.cycles c
    where c.kuri_id = v_cycle.kuri_id
      and c.cycle_number = v_cycle.cycle_number + 1
      and c.status <> 'CANCELLED'
      and new_period_end >= c.period_start
  ) then
    raise exception 'Cycle period overlaps the next cycle.';
  end if;

  insert into public.cycle_schedule_overrides (
    cycle_id,
    kuri_id,
    previous_period_start,
    previous_period_end,
    previous_due_date,
    previous_draw_date,
    new_period_start,
    new_period_end,
    new_due_date,
    new_draw_date,
    reason,
    changed_by
  )
  values (
    v_cycle.id,
    v_cycle.kuri_id,
    v_cycle.period_start,
    v_cycle.period_end,
    v_cycle.due_date,
    v_cycle.draw_date,
    new_period_start,
    new_period_end,
    new_due_date,
    new_draw_date,
    btrim(reason_text),
    (select id from public.users where id = v_actor)
  );

  update public.cycles
  set period_start = new_period_start,
      period_end = new_period_end,
      due_date = new_due_date,
      draw_date = new_draw_date
  where id = v_cycle.id
  returning * into v_cycle;

  update public.installments i
  set due_date = v_cycle.due_date,
      updated_at = now()
  where i.cycle_id = v_cycle.id
    and i.status in ('UNPAID','PARTIAL');

  return v_cycle;
end;
$function$;

revoke all on table public.cycle_schedule_overrides from public, anon, authenticated;
grant select on table public.cycle_schedule_overrides to authenticated;

revoke execute on function public.override_future_cycle_schedule_for_admin(
  uuid,date,date,date,date,text
) from public, anon;
grant execute on function public.override_future_cycle_schedule_for_admin(
  uuid,date,date,date,date,text
) to authenticated;
