-- CYCLE-006: allow progressive CUSTOM schedule generation.
create or replace function public.generate_kuri_schedule_for_admin(target_kuri_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  kuri_row public.kuris%rowtype;
  current_cycle_id uuid;
  membership_count integer;
  custom_count integer;
  custom_generated_count integer := 0;
  created_cycles integer := 0;
  v_cycle_start date;
  v_cycle_end date;
  v_due_date date;
  v_draw_date date;
  custom_row public.kuri_custom_cycle_schedules%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.*
  into kuri_row
  from public.kuris k
  where k.id = target_kuri_id
    and public.has_kuri_admin_role(k.id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update;

  if not found then
    raise exception 'You do not have permission to manage this Kuri.';
  end if;

  select count(*) into membership_count
  from public.memberships m
  where m.kuri_id = target_kuri_id;

  if membership_count = 0 then
    raise exception 'Add at least one membership before generating the schedule.';
  end if;

  if kuri_row.schedule_mode = 'CUSTOM'::public.kuri_schedule_mode then
    select count(*) into custom_count
    from public.kuri_custom_cycle_schedules s
    where s.kuri_id = target_kuri_id;

    if custom_count = 0 then
      raise exception 'Define at least one custom cycle before generating the schedule.';
    end if;

    for i in 1..kuri_row.number_of_cycles loop
      if exists (
        select 1
        from public.cycles c
        where c.kuri_id = target_kuri_id
          and c.cycle_number = i
      ) then
        custom_generated_count := i;
      elsif exists (
        select 1
        from public.kuri_custom_cycle_schedules s
        where s.kuri_id = target_kuri_id
          and s.cycle_number = i
      ) then
        custom_generated_count := i;
      else
        exit;
      end if;
    end loop;

    if custom_generated_count = 0 then
      raise exception 'Custom schedule must define cycle 1 before generation.';
    end if;

    for i in 1..custom_generated_count loop
      select s.*
      into custom_row
      from public.kuri_custom_cycle_schedules s
      where s.kuri_id = target_kuri_id
        and s.cycle_number = i;

      if not found then
        raise exception 'Custom schedule is missing cycle %; define cycles consecutively.', i;
      end if;

      v_cycle_start := custom_row.period_start;
      v_cycle_end := custom_row.period_end;
      v_due_date := custom_row.due_date;
      v_draw_date := custom_row.draw_date;

      current_cycle_id := null;

      insert into public.cycles(
        kuri_id,cycle_number,period_start,period_end,due_date,draw_date,status
      )
      values(
        target_kuri_id,i,v_cycle_start,v_cycle_end,v_due_date,v_draw_date,'UPCOMING'
      )
      on conflict(kuri_id,cycle_number) do nothing
      returning id into current_cycle_id;

      if current_cycle_id is null then
        select c.id into current_cycle_id
        from public.cycles c
        where c.kuri_id = target_kuri_id
          and c.cycle_number = i;
      else
        created_cycles := created_cycles + 1;
      end if;

      insert into public.installments(
        membership_id,cycle_id,amount_due,amount_paid,status,due_date
      )
      select
        m.id,current_cycle_id,kuri_row.installment_amount,0,
        'UNPAID'::public.installment_status,c.due_date
      from public.memberships m
      join public.cycles c on c.id = current_cycle_id
      where m.kuri_id = target_kuri_id
        and c.status not in ('COMPLETED','CANCELLED')
      on conflict(membership_id,cycle_id) do nothing;
    end loop;
  else
    for i in 1..kuri_row.number_of_cycles loop
      if kuri_row.frequency = 'WEEKLY'::public.kuri_frequency then
        v_cycle_start := (kuri_row.start_date+((i-1)*interval '1 week'))::date;
        v_cycle_end := (v_cycle_start+interval '6 days')::date;
        v_due_date := v_cycle_start+((kuri_row.due_day-1)*interval '1 day')
          -((extract(isodow from v_cycle_start)::integer-1)*interval '1 day');
        v_draw_date := v_cycle_start+((kuri_row.draw_day-1)*interval '1 day')
          -((extract(isodow from v_cycle_start)::integer-1)*interval '1 day');
      elsif kuri_row.frequency = 'MONTHLY'::public.kuri_frequency then
        v_cycle_start := (kuri_row.start_date+((i-1)*interval '1 month'))::date;
        v_cycle_end := (v_cycle_start+interval '1 month'-interval '1 day')::date;
        v_due_date := make_date(
          extract(year from v_cycle_start)::integer,
          extract(month from v_cycle_start)::integer,
          least(kuri_row.due_day,extract(day from v_cycle_end)::integer)
        );
        v_draw_date := make_date(
          extract(year from v_cycle_start)::integer,
          extract(month from v_cycle_start)::integer,
          least(kuri_row.draw_day,extract(day from v_cycle_end)::integer)
        );
      elsif kuri_row.frequency = 'YEARLY'::public.kuri_frequency then
        v_cycle_start := (kuri_row.start_date+((i-1)*interval '1 year'))::date;
        v_cycle_end := (v_cycle_start+interval '1 year'-interval '1 day')::date;
        v_due_date := least(v_cycle_end,v_cycle_start+((kuri_row.due_day-1)*interval '1 day'));
        v_draw_date := least(v_cycle_end,v_cycle_start+((kuri_row.draw_day-1)*interval '1 day'));
      else
        raise exception 'Unsupported Kuri frequency.';
      end if;

      current_cycle_id := null;

      insert into public.cycles(
        kuri_id,cycle_number,period_start,period_end,due_date,draw_date,status
      )
      values(
        target_kuri_id,i,v_cycle_start,v_cycle_end,v_due_date,v_draw_date,'UPCOMING'
      )
      on conflict(kuri_id,cycle_number) do nothing
      returning id into current_cycle_id;

      if current_cycle_id is null then
        select c.id into current_cycle_id
        from public.cycles c
        where c.kuri_id=target_kuri_id and c.cycle_number=i;
      else
        created_cycles := created_cycles+1;
      end if;

      insert into public.installments(
        membership_id,cycle_id,amount_due,amount_paid,status,due_date
      )
      select
        m.id,current_cycle_id,kuri_row.installment_amount,0,
        'UNPAID'::public.installment_status,c.due_date
      from public.memberships m
      join public.cycles c on c.id=current_cycle_id
      where m.kuri_id=target_kuri_id
        and c.status not in ('COMPLETED','CANCELLED')
      on conflict(membership_id,cycle_id) do nothing;
    end loop;
  end if;

  perform public.sync_expense_obligations_for_kuri(target_kuri_id);

  return created_cycles;
end;
$function$;