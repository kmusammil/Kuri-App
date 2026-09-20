-- Fix PL/pgSQL variable/column ambiguity in generate_cycles_for_admin.
-- Superseded immediately by v2, which removes the ambiguous variable name.

CREATE OR REPLACE FUNCTION public.generate_cycles_for_admin(target_kuri_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
      m.id, cycle_id, membership_amount, 0, 'UNPAID', due_date
    from public.memberships m
    where m.kuri_id = target_kuri_id
      and not exists (
        select 1
        from public.installments i
        where i.membership_id = m.id
          and i.cycle_id = generate_cycles_for_admin.cycle_id
      )
    on conflict (membership_id, cycle_id) do nothing;

    inserted_cycles := inserted_cycles + 1;
  end loop;

  select count(*) into cycle_memberships
  from public.memberships m
  where m.kuri_id = target_kuri_id;

  return inserted_cycles;
end;
$function$;