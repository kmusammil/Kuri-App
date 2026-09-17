begin;

-- Generate the complete monthly cycle schedule and one installment per
-- membership for each cycle. The operation is idempotent: existing cycles and
-- installments are reused rather than duplicated.
create or replace function public.generate_cycles_for_admin(target_kuri_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  kuri_org_id uuid;
  cycle_id uuid;
  cycle_start date;
  cycle_end date;
  due_date date;
  draw_date date;
  cycle_no integer;
  inserted_cycles integer := 0;
  cycle_memberships integer;
  total_cycles integer;
  membership_amount bigint;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.organization_id, k.start_date, k.number_of_cycles, k.installment_amount
    into kuri_org_id, cycle_start, total_cycles, membership_amount
  from public.kuris k
  join public.organization_users ou
    on ou.organization_id = k.organization_id
   and ou.user_id = auth.uid()
   and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  where k.id = target_kuri_id
  limit 1;

  if kuri_org_id is null then
    raise exception 'You do not have permission to manage cycles for this Kuri.';
  end if;

  for cycle_no in 1..total_cycles loop
    cycle_start := (select k.start_date from public.kuris k where k.id = target_kuri_id) + ((cycle_no - 1) * interval '1 month');
    cycle_end := (cycle_start + interval '1 month' - interval '1 day')::date;

    select make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(
        (select k.due_day from public.kuris k where k.id = target_kuri_id),
        extract(day from (date_trunc('month', cycle_start) + interval '1 month - 1 day'))::integer
      )
    ) into due_date;

    select make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(
        (select k.draw_day from public.kuris k where k.id = target_kuri_id),
        extract(day from (date_trunc('month', cycle_start) + interval '1 month - 1 day'))::integer
      )
    ) into draw_date;

    insert into public.cycles (
      kuri_id, cycle_number, period_start, period_end, due_date, draw_date, status
    ) values (
      target_kuri_id, cycle_no, cycle_start, cycle_end, due_date, draw_date, 'UPCOMING'
    )
    on conflict (kuri_id, cycle_number) do update
      set period_start = excluded.period_start,
          period_end = excluded.period_end,
          due_date = excluded.due_date,
          draw_date = excluded.draw_date;

    select c.id into cycle_id
    from public.cycles c
    where c.kuri_id = target_kuri_id
      and c.cycle_number = cycle_no;

    insert into public.installments (
      membership_id, cycle_id, amount_due, amount_paid, status, due_date
    )
    select
      m.id,
      cycle_id,
      membership_amount,
      0,
      'UNPAID',
      due_date
    from public.memberships m
    where m.kuri_id = target_kuri_id
      and not exists (
        select 1
        from public.installments i
        where i.membership_id = m.id
          and i.cycle_id = cycle_id
      )
    on conflict (membership_id, cycle_id) do nothing;

    inserted_cycles := inserted_cycles + 1;
  end loop;

  select count(*) into cycle_memberships
  from public.memberships m
  where m.kuri_id = target_kuri_id;

  return inserted_cycles;
end;
$$;

create or replace function public.list_cycles_for_admin(target_kuri_id uuid)
returns table (
  id uuid,
  cycle_number integer,
  period_start date,
  period_end date,
  due_date date,
  draw_date date,
  status public.cycle_status,
  installment_count bigint,
  paid_installment_count bigint
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
    count(i.id) as installment_count,
    count(i.id) filter (where i.status in ('PAID','PAID_LATE')) as paid_installment_count
  from public.cycles c
  join public.kuris k on k.id = c.kuri_id
  left join public.installments i on i.cycle_id = c.id
  where c.kuri_id = target_kuri_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id = k.organization_id
        and ou.user_id = auth.uid()
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  group by c.id, c.cycle_number, c.period_start, c.period_end, c.due_date, c.draw_date, c.status
  order by c.cycle_number;
$$;

revoke all on function public.generate_cycles_for_admin(uuid) from public;
revoke all on function public.list_cycles_for_admin(uuid) from public;
grant execute on function public.generate_cycles_for_admin(uuid) to authenticated;
grant execute on function public.list_cycles_for_admin(uuid) to authenticated;

commit;
