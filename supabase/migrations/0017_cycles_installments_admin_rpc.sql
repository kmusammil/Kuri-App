begin;

-- Generate the complete monthly schedule for a Kuri and create one
-- installment for every membership in every cycle. The operation is
-- idempotent: existing cycles/installments are preserved.
create or replace function public.generate_kuri_schedule_for_admin(target_kuri_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  kuri_row public.kuris%rowtype;
  cycle_id uuid;
  membership_count integer;
  created_cycles integer := 0;
  cycle_start date;
  cycle_end date;
  due_date date;
  draw_date date;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.* into kuri_row
  from public.kuris k
  where k.id = target_kuri_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.user_id = auth.uid()
        and ou.organization_id = k.organization_id
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );

  if not found then
    raise exception 'You do not have permission to manage this Kuri.';
  end if;

  select count(*) into membership_count
  from public.memberships m
  where m.kuri_id = target_kuri_id;

  if membership_count = 0 then
    raise exception 'Add at least one membership before generating the schedule.';
  end if;

  for i in 1..kuri_row.number_of_cycles loop
    cycle_start := (kuri_row.start_date + ((i - 1) * interval '1 month'))::date;
    cycle_end := (cycle_start + interval '1 month' - interval '1 day')::date;
    due_date := make_date(extract(year from cycle_start)::integer, extract(month from cycle_start)::integer, least(kuri_row.due_day, extract(day from cycle_end)::integer));
    draw_date := make_date(extract(year from cycle_start)::integer, extract(month from cycle_start)::integer, least(kuri_row.draw_day, extract(day from cycle_end)::integer));

    insert into public.cycles (
      kuri_id, cycle_number, period_start, period_end, due_date, draw_date, status
    )
    values (
      target_kuri_id, i, cycle_start, cycle_end, due_date, draw_date, 'UPCOMING'
    )
    on conflict (kuri_id, cycle_number) do nothing
    returning id into cycle_id;

    if cycle_id is null then
      select c.id into cycle_id
      from public.cycles c
      where c.kuri_id = target_kuri_id
        and c.cycle_number = i;
    else
      created_cycles := created_cycles + 1;
    end if;

    insert into public.installments (
      membership_id, cycle_id, amount_due, amount_paid, status, due_date
    )
    select
      m.id,
      cycle_id,
      kuri_row.installment_amount,
      0,
      'UNPAID',
      due_date
    from public.memberships m
    where m.kuri_id = target_kuri_id
    on conflict (membership_id, cycle_id) do nothing;
  end loop;

  return created_cycles;
end;
$$;

-- Remote history already contains list_cycles_for_admin with a different
-- return shape. PostgreSQL cannot replace a function when its OUT row type
-- changes, so remove that old definition before recreating the intended one.
drop function if exists public.list_cycles_for_admin(uuid);

create function public.list_cycles_for_admin(target_kuri_id uuid)
returns table (
  id uuid,
  cycle_number integer,
  period_start date,
  period_end date,
  due_date date,
  draw_date date,
  status public.cycle_status,
  installment_count bigint
)
language sql
security definer
set search_path = public
stable
as $$
  select
    c.id,
    c.cycle_number,
    c.period_start,
    c.period_end,
    c.due_date,
    c.draw_date,
    c.status,
    count(i.id) as installment_count
  from public.cycles c
  join public.kuris k on k.id = c.kuri_id
  left join public.installments i on i.cycle_id = c.id
  where c.kuri_id = target_kuri_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.user_id = auth.uid()
        and ou.organization_id = k.organization_id
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  group by c.id
  order by c.cycle_number;
$$;

revoke all on function public.generate_kuri_schedule_for_admin(uuid) from public;
revoke all on function public.list_cycles_for_admin(uuid) from public;

grant execute on function public.generate_kuri_schedule_for_admin(uuid) to authenticated;
grant execute on function public.list_cycles_for_admin(uuid) to authenticated;

commit;
