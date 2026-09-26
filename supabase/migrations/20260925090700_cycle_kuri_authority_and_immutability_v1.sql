BEGIN;

CREATE OR REPLACE FUNCTION public.generate_cycles_for_admin(target_kuri_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  kuri_row public.kuris%rowtype;
  v_cycle_id uuid;
  cycle_start date;
  cycle_end date;
  due_date date;
  draw_date date;
  cycle_no integer;
  inserted_cycles integer := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT k.*
    INTO kuri_row
  FROM public.kuris k
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(
      k.id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'You do not have permission to manage cycles for this Kuri.';
  END IF;

  FOR cycle_no IN 1..kuri_row.number_of_cycles LOOP
    cycle_start := (kuri_row.start_date + ((cycle_no - 1) * interval '1 month'))::date;
    cycle_end := (cycle_start + interval '1 month' - interval '1 day')::date;

    due_date := make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.due_day,extract(day from cycle_end)::integer)
    );

    draw_date := make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.draw_day,extract(day from cycle_end)::integer)
    );

    INSERT INTO public.cycles(
      kuri_id,cycle_number,period_start,period_end,due_date,draw_date,status
    )
    VALUES(
      target_kuri_id,cycle_no,cycle_start,cycle_end,due_date,draw_date,'UPCOMING'
    )
    ON CONFLICT(kuri_id,cycle_number) DO UPDATE
      SET period_start=EXCLUDED.period_start,
          period_end=EXCLUDED.period_end,
          due_date=EXCLUDED.due_date,
          draw_date=EXCLUDED.draw_date
      WHERE public.cycles.status NOT IN ('COMPLETED','CANCELLED');

    SELECT c.id
      INTO v_cycle_id
    FROM public.cycles c
    WHERE c.kuri_id=target_kuri_id
      AND c.cycle_number=cycle_no;

    INSERT INTO public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    SELECT m.id,v_cycle_id,kuri_row.installment_amount,0,'UNPAID',due_date
    FROM public.memberships m
    WHERE m.kuri_id=target_kuri_id
    ON CONFLICT(membership_id,cycle_id) DO NOTHING;

    inserted_cycles:=inserted_cycles+1;
  END LOOP;

  RETURN inserted_cycles;
END;
$function$


CREATE OR REPLACE FUNCTION public.generate_kuri_schedule_for_admin(target_kuri_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  kuri_row public.kuris%rowtype;
  current_cycle_id uuid;
  membership_count integer;
  created_cycles integer := 0;
  cycle_start date;
  cycle_end date;
  due_date date;
  draw_date date;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT k.*
    INTO kuri_row
  FROM public.kuris k
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(
      k.id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'You do not have permission to manage this Kuri.';
  END IF;

  SELECT count(*)
    INTO membership_count
  FROM public.memberships m
  WHERE m.kuri_id=target_kuri_id;

  IF membership_count=0 THEN
    RAISE EXCEPTION 'Add at least one membership before generating the schedule.';
  END IF;

  FOR i IN 1..kuri_row.number_of_cycles LOOP
    cycle_start := (kuri_row.start_date + ((i - 1) * interval '1 month'))::date;
    cycle_end := (cycle_start + interval '1 month' - interval '1 day')::date;

    due_date := make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.due_day,extract(day from cycle_end)::integer)
    );

    draw_date := make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.draw_day,extract(day from cycle_end)::integer)
    );

    current_cycle_id:=NULL;

    INSERT INTO public.cycles(
      kuri_id,cycle_number,period_start,period_end,due_date,draw_date,status
    )
    VALUES(
      target_kuri_id,i,cycle_start,cycle_end,due_date,draw_date,'UPCOMING'
    )
    ON CONFLICT(kuri_id,cycle_number) DO NOTHING
    RETURNING id INTO current_cycle_id;

    IF current_cycle_id IS NULL THEN
      SELECT c.id
        INTO current_cycle_id
      FROM public.cycles c
      WHERE c.kuri_id=target_kuri_id
        AND c.cycle_number=i;
    ELSE
      created_cycles:=created_cycles+1;
    END IF;

    INSERT INTO public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    SELECT m.id,current_cycle_id,kuri_row.installment_amount,0,'UNPAID',due_date
    FROM public.memberships m
    WHERE m.kuri_id=target_kuri_id
    ON CONFLICT(membership_id,cycle_id) DO NOTHING;
  END LOOP;

  RETURN created_cycles;
END;
$function$


CREATE OR REPLACE FUNCTION public.get_cycle_for_admin(target_cycle_id uuid)
 RETURNS TABLE(id uuid, kuri_id uuid, cycle_number integer, period_start date, period_end date, due_date date, draw_date date, status cycle_status)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT c.id,c.kuri_id,c.cycle_number,c.period_start,c.period_end,
         c.due_date,c.draw_date,c.status
  FROM public.cycles c
  WHERE c.id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );
$function$


CREATE OR REPLACE FUNCTION public.list_cycles_for_admin(target_kuri_id uuid)
 RETURNS TABLE(id uuid, cycle_number integer, period_start date, period_end date, due_date date, draw_date date, status cycle_status, installment_count bigint, paid_installment_count bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT c.id,c.cycle_number,c.period_start,c.period_end,c.due_date,c.draw_date,
         c.status,count(i.id),
         count(i.id) FILTER (WHERE i.status IN ('PAID','PAID_LATE'))
  FROM public.cycles c
  LEFT JOIN public.installments i ON i.cycle_id=c.id
  WHERE c.kuri_id=target_kuri_id
    AND public.has_kuri_admin_role(
      c.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  GROUP BY c.id,c.cycle_number,c.period_start,c.period_end,c.due_date,c.draw_date,c.status
  ORDER BY c.cycle_number;
$function$


CREATE OR REPLACE FUNCTION public.transition_cycle_status_for_admin(target_cycle_id uuid, target_status cycle_status)
 RETURNS cycle_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  current_status public.cycle_status;
  target_kuri_id uuid;
  finalized_draw_count integer;
  winner_count integer;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT c.status,c.kuri_id
    INTO current_status,target_kuri_id
  FROM public.cycles c
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE c.id=target_cycle_id
  FOR UPDATE OF c,k;

  IF target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Cycle not found.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to change this cycle status.';
  END IF;

  IF current_status=target_status THEN
    RETURN current_status;
  END IF;

  IF NOT (
    (current_status='UPCOMING' AND target_status='OPEN')
    OR (current_status='OPEN' AND target_status='PAYMENT_CLOSED')
    OR (current_status='PAYMENT_CLOSED' AND target_status='DRAW_PENDING')
    OR (current_status='DRAW_PENDING' AND target_status='COMPLETED')
    OR (
      current_status IN ('UPCOMING','OPEN','PAYMENT_CLOSED','DRAW_PENDING')
      AND target_status='CANCELLED'
    )
  ) THEN
    RAISE EXCEPTION 'Invalid cycle status transition: % -> %.',current_status,target_status;
  END IF;

  IF current_status='DRAW_PENDING' AND target_status='COMPLETED' THEN
    SELECT count(*)
      INTO finalized_draw_count
    FROM public.draw_sessions d
    WHERE d.cycle_id=target_cycle_id
      AND d.kuri_id=target_kuri_id
      AND d.status='FINALIZED';

    SELECT count(*)
      INTO winner_count
    FROM public.monthly_winners mw
    WHERE mw.cycle_id=target_cycle_id;

    IF finalized_draw_count<>1 THEN
      RAISE EXCEPTION 'Cycle cannot be completed until its draw is FINALIZED.';
    END IF;

    IF winner_count<1 THEN
      RAISE EXCEPTION 'Cycle cannot be completed without at least one finalized winner.';
    END IF;
  END IF;

  UPDATE public.cycles
  SET status=target_status
  WHERE id=target_cycle_id;

  RETURN target_status;
END;
$function$


REVOKE ALL ON FUNCTION public.generate_cycles_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.generate_kuri_schedule_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_cycle_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_cycles_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.transition_cycle_status_for_admin(uuid,public.cycle_status) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.generate_cycles_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_kuri_schedule_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_cycle_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_cycles_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transition_cycle_status_for_admin(uuid,public.cycle_status) TO authenticated;

COMMIT;