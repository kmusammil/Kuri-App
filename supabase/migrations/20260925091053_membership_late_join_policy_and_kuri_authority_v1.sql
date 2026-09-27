BEGIN;

CREATE OR REPLACE FUNCTION public.create_membership_for_admin(target_kuri_id uuid, target_person_id uuid, target_membership_number text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  membership_id_value uuid;
  target_org_id uuid;
  target_kuri_status public.kuri_status;
  target_limit integer;
  current_membership_count integer;
  cycle_row record;
  person_exists boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT k.organization_id,k.status,k.membership_limit
    INTO target_org_id,target_kuri_status,target_limit
  FROM public.kuris k
  WHERE k.id=target_kuri_id
  FOR UPDATE;

  IF target_org_id IS NULL THEN
    RAISE EXCEPTION 'Kuri not found.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to add memberships.';
  END IF;

  IF target_kuri_status NOT IN ('OPEN','ACTIVE') THEN
    RAISE EXCEPTION 'Memberships can only be added to an OPEN or ACTIVE Kuri.';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.people p
    WHERE p.id=target_person_id
      AND p.organization_id=target_org_id
  )
  INTO person_exists;

  IF NOT person_exists THEN
    RAISE EXCEPTION 'Person not found in this organization.';
  END IF;

  SELECT count(*)
    INTO current_membership_count
  FROM public.memberships m
  WHERE m.kuri_id=target_kuri_id;

  IF current_membership_count>=target_limit THEN
    RAISE EXCEPTION 'Kuri membership limit has been reached.';
  END IF;

  INSERT INTO public.memberships(
    kuri_id,person_id,membership_number,status
  )
  VALUES(
    target_kuri_id,
    target_person_id,
    nullif(btrim(target_membership_number),''),
    'ACTIVE'
  )
  RETURNING id INTO membership_id_value;

  -- Late-joining policy: do not create retroactive obligations for terminal
  -- cycles. This preserves finalized historical draws/cycles and leaves
  -- current/future non-terminal cycles available to the new member.
  FOR cycle_row IN
    SELECT id,due_date
    FROM public.cycles
    WHERE kuri_id=target_kuri_id
      AND status NOT IN ('COMPLETED','CANCELLED')
    ORDER BY cycle_number
  LOOP
    INSERT INTO public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    SELECT
      membership_id_value,
      cycle_row.id,
      k.installment_amount,
      0,
      'UNPAID'::public.installment_status,
      cycle_row.due_date
    FROM public.kuris k
    WHERE k.id=target_kuri_id
    ON CONFLICT(membership_id,cycle_id) DO NOTHING;
  END LOOP;

  RETURN membership_id_value;
END;
$function$


CREATE OR REPLACE FUNCTION public.list_memberships_for_admin(target_kuri_id uuid)
 RETURNS TABLE(id uuid, kuri_id uuid, person_id uuid, membership_number text, status membership_status, joined_at timestamp with time zone, registered_name text, display_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    m.id,m.kuri_id,m.person_id,m.membership_number,m.status,m.joined_at,
    p.registered_name,p.display_name
  FROM public.memberships m
  JOIN public.people p ON p.id=m.person_id
  WHERE m.kuri_id=target_kuri_id
    AND public.has_kuri_admin_role(
      m.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY m.membership_number;
$function$


CREATE OR REPLACE FUNCTION public.transition_membership_status_for_admin(target_membership_id uuid, target_status membership_status)
 RETURNS membership_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  current_status public.membership_status;
  target_kuri_id uuid;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT m.status,m.kuri_id
    INTO current_status,target_kuri_id
  FROM public.memberships m
  JOIN public.kuris k ON k.id=m.kuri_id
  WHERE m.id=target_membership_id
  FOR UPDATE OF m,k;

  IF target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Membership not found.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to change this membership status.';
  END IF;

  IF current_status=target_status THEN
    RETURN current_status;
  END IF;

  IF NOT (
    (current_status='PENDING' AND target_status='ACTIVE')
    OR (current_status='ACTIVE' AND target_status IN ('SUSPENDED','EXITED','COMPLETED','TRANSFERRED'))
    OR (current_status='SUSPENDED' AND target_status IN ('ACTIVE','EXITED','COMPLETED','TRANSFERRED'))
  ) THEN
    RAISE EXCEPTION 'Invalid membership status transition: % -> %.',current_status,target_status;
  END IF;

  UPDATE public.memberships
  SET status=target_status,
      exited_at=CASE
        WHEN target_status='EXITED' THEN coalesce(exited_at,now())
        ELSE exited_at
      END,
      completed_at=CASE
        WHEN target_status='COMPLETED' THEN coalesce(completed_at,now())
        ELSE completed_at
      END
  WHERE id=target_membership_id;

  RETURN target_status;
END;
$function$


CREATE OR REPLACE FUNCTION public.list_people_available_for_membership(target_kuri_id uuid)
 RETURNS TABLE(id uuid, registered_name text, display_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT p.id,p.registered_name,p.display_name
  FROM public.people p
  JOIN public.kuris k ON k.organization_id=p.organization_id
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(
      k.id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY coalesce(nullif(p.display_name,''),p.registered_name),p.registered_name;
$function$


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
  inserted_cycles integer:=0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT k.*
    INTO kuri_row
  FROM public.kuris k
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(
      k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'You do not have permission to manage cycles for this Kuri.';
  END IF;

  FOR cycle_no IN 1..kuri_row.number_of_cycles LOOP
    cycle_start:=(kuri_row.start_date+((cycle_no-1)*interval '1 month'))::date;
    cycle_end:=(cycle_start+interval '1 month'-interval '1 day')::date;

    due_date:=make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.due_day,extract(day from cycle_end)::integer)
    );

    draw_date:=make_date(
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
    JOIN public.cycles c ON c.id=v_cycle_id
    WHERE m.kuri_id=target_kuri_id
      AND c.status NOT IN ('COMPLETED','CANCELLED')
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
  created_cycles integer:=0;
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
      k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'You do not have permission to manage this Kuri.';
  END IF;

  SELECT count(*) INTO membership_count
  FROM public.memberships m
  WHERE m.kuri_id=target_kuri_id;

  IF membership_count=0 THEN
    RAISE EXCEPTION 'Add at least one membership before generating the schedule.';
  END IF;

  FOR i IN 1..kuri_row.number_of_cycles LOOP
    cycle_start:=(kuri_row.start_date+((i-1)*interval '1 month'))::date;
    cycle_end:=(cycle_start+interval '1 month'-interval '1 day')::date;

    due_date:=make_date(
      extract(year from cycle_start)::integer,
      extract(month from cycle_start)::integer,
      least(kuri_row.due_day,extract(day from cycle_end)::integer)
    );

    draw_date:=make_date(
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
      SELECT c.id INTO current_cycle_id
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
    JOIN public.cycles c ON c.id=current_cycle_id
    WHERE m.kuri_id=target_kuri_id
      AND c.status NOT IN ('COMPLETED','CANCELLED')
    ON CONFLICT(membership_id,cycle_id) DO NOTHING;
  END LOOP;

  RETURN created_cycles;
END;
$function$


REVOKE ALL ON FUNCTION public.create_membership_for_admin(uuid,uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_memberships_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.transition_membership_status_for_admin(uuid,public.membership_status) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_people_available_for_membership(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.generate_cycles_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.generate_kuri_schedule_for_admin(uuid) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.create_membership_for_admin(uuid,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_memberships_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.transition_membership_status_for_admin(uuid,public.membership_status) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_people_available_for_membership(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_cycles_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.generate_kuri_schedule_for_admin(uuid) TO authenticated;

COMMIT;