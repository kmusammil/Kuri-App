-- Complete Expense frequency normalization after the enum value is committed.
-- Legacy PER_CYCLE is accepted only as an input alias and normalized to RECURRING.

ALTER TABLE public.expense_rules
  DROP CONSTRAINT IF EXISTS expense_rules_recurrence_shape;

ALTER TABLE public.expense_rules
  ADD CONSTRAINT expense_rules_recurrence_shape
  CHECK (
    (
      frequency = 'ONE_TIME'::public.expense_frequency
      AND recurrence_pattern IS NULL
      AND recurrence_interval IS NULL
      AND recurrence_start_date IS NULL
      AND recurrence_end_date IS NULL
    )
    OR
    (
      frequency = 'RECURRING'::public.expense_frequency
      AND recurrence_pattern IS NOT NULL
    )
  );

CREATE OR REPLACE FUNCTION public.create_expense_rule_for_admin(
  target_kuri_id uuid,
  expense_name text,
  expense_description text,
  expense_frequency_value public.expense_frequency,
  expense_amount bigint,
  activate_rule boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  actor_id uuid := auth.uid();
  kuri_status_value public.kuri_status;
  rule_id uuid;
  normalized_frequency public.expense_frequency;
BEGIN
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to manage Expenses for this Kuri.';
  END IF;

  SELECT k.status INTO kuri_status_value
  FROM public.kuris k
  WHERE k.id=target_kuri_id
  FOR UPDATE;

  IF kuri_status_value IS NULL THEN
    RAISE EXCEPTION 'Kuri not found.';
  END IF;

  IF kuri_status_value IN ('COMPLETED','ARCHIVED') THEN
    RAISE EXCEPTION 'Expense rules cannot be added to a completed or archived Kuri.';
  END IF;

  IF char_length(btrim(coalesce(expense_name,''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Expense name must be 1-200 characters.';
  END IF;

  IF expense_amount IS NULL OR expense_amount<=0 THEN
    RAISE EXCEPTION 'Expense amount must be greater than zero.';
  END IF;

  IF expense_frequency_value IS NULL THEN
    RAISE EXCEPTION 'Expense frequency is required.';
  END IF;

  normalized_frequency := CASE expense_frequency_value::text
    WHEN 'ONE_TIME' THEN 'ONE_TIME'::public.expense_frequency
    WHEN 'PER_CYCLE' THEN 'RECURRING'::public.expense_frequency
    WHEN 'RECURRING' THEN 'RECURRING'::public.expense_frequency
    ELSE NULL
  END;

  IF normalized_frequency IS NULL THEN
    RAISE EXCEPTION 'Unsupported Expense frequency.';
  END IF;

  INSERT INTO public.expense_rules(
    kuri_id,name,description,frequency,amount,active,created_by,recurrence_pattern
  )
  VALUES(
    target_kuri_id,
    btrim(expense_name),
    nullif(btrim(expense_description),''),
    normalized_frequency,
    expense_amount,
    coalesce(activate_rule,true),
    (SELECT id FROM public.users WHERE id=actor_id),
    CASE
      WHEN normalized_frequency='RECURRING'::public.expense_frequency
      THEN 'PER_CYCLE'::public.expense_recurrence_pattern
      ELSE NULL
    END
  )
  RETURNING id INTO rule_id;

  PERFORM public.sync_expense_obligations_for_rule(rule_id);
  RETURN rule_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.create_expense_rule_for_admin(
  target_kuri_id uuid,
  expense_name text,
  expense_description text,
  expense_frequency_value public.expense_frequency,
  expense_amount bigint,
  recurrence_pattern_value public.expense_recurrence_pattern,
  recurrence_interval_value integer DEFAULT NULL,
  recurrence_start_date_value date DEFAULT NULL,
  recurrence_end_date_value date DEFAULT NULL,
  custom_schedule_dates date[] DEFAULT NULL,
  activate_rule boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  actor_id uuid := auth.uid();
  kuri_status_value public.kuri_status;
  rule_id uuid;
  schedule_date date;
  normalized_frequency public.expense_frequency;
BEGIN
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to manage Expenses for this Kuri.';
  END IF;

  SELECT k.status INTO kuri_status_value
  FROM public.kuris k
  WHERE k.id=target_kuri_id
  FOR UPDATE;

  IF kuri_status_value IS NULL THEN
    RAISE EXCEPTION 'Kuri not found.';
  END IF;

  IF kuri_status_value IN ('COMPLETED','ARCHIVED') THEN
    RAISE EXCEPTION 'Expense rules cannot be added to a completed or archived Kuri.';
  END IF;

  IF char_length(btrim(coalesce(expense_name,''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Expense name must be 1-200 characters.';
  END IF;

  IF expense_amount IS NULL OR expense_amount<=0 THEN
    RAISE EXCEPTION 'Expense amount must be greater than zero.';
  END IF;

  IF expense_frequency_value IS NULL THEN
    RAISE EXCEPTION 'Expense frequency is required.';
  END IF;

  normalized_frequency := CASE expense_frequency_value::text
    WHEN 'ONE_TIME' THEN 'ONE_TIME'::public.expense_frequency
    WHEN 'PER_CYCLE' THEN 'RECURRING'::public.expense_frequency
    WHEN 'RECURRING' THEN 'RECURRING'::public.expense_frequency
    ELSE NULL
  END;

  IF normalized_frequency IS NULL THEN
    RAISE EXCEPTION 'Unsupported Expense frequency.';
  END IF;

  IF normalized_frequency='ONE_TIME'::public.expense_frequency THEN
    IF recurrence_pattern_value IS NOT NULL
       OR recurrence_interval_value IS NOT NULL
       OR recurrence_start_date_value IS NOT NULL
       OR recurrence_end_date_value IS NOT NULL
       OR coalesce(cardinality(custom_schedule_dates),0)>0 THEN
      RAISE EXCEPTION 'One-time Expenses cannot have recurrence settings.';
    END IF;
  ELSE
    IF recurrence_pattern_value IS NULL THEN
      RAISE EXCEPTION 'Recurring Expense requires a recurrence pattern.';
    END IF;

    IF recurrence_pattern_value='PER_CYCLE'::public.expense_recurrence_pattern THEN
      IF recurrence_interval_value IS NOT NULL
         OR recurrence_start_date_value IS NOT NULL
         OR recurrence_end_date_value IS NOT NULL
         OR coalesce(cardinality(custom_schedule_dates),0)>0 THEN
        RAISE EXCEPTION 'Per-cycle Expenses cannot have calendar recurrence settings.';
      END IF;
    ELSIF recurrence_pattern_value IN (
      'WEEKLY'::public.expense_recurrence_pattern,
      'MONTHLY'::public.expense_recurrence_pattern,
      'YEARLY'::public.expense_recurrence_pattern
    ) THEN
      IF coalesce(recurrence_interval_value,1)<=0 THEN
        RAISE EXCEPTION 'Recurrence interval must be greater than zero.';
      END IF;

      IF coalesce(cardinality(custom_schedule_dates),0)>0 THEN
        RAISE EXCEPTION 'Calendar recurrence cannot have custom schedule dates.';
      END IF;

      IF recurrence_end_date_value IS NOT NULL
         AND recurrence_end_date_value < coalesce(recurrence_start_date_value,current_date) THEN
        RAISE EXCEPTION 'Recurrence end date cannot be before the start date.';
      END IF;
    ELSIF recurrence_pattern_value='CUSTOM'::public.expense_recurrence_pattern THEN
      IF coalesce(cardinality(custom_schedule_dates),0)=0 THEN
        RAISE EXCEPTION 'Custom recurrence requires at least one schedule date.';
      END IF;

      IF recurrence_interval_value IS NOT NULL THEN
        RAISE EXCEPTION 'Custom recurrence cannot have a recurrence interval.';
      END IF;

      IF recurrence_end_date_value IS NOT NULL
         AND recurrence_end_date_value < coalesce(recurrence_start_date_value,current_date) THEN
        RAISE EXCEPTION 'Recurrence end date cannot be before the start date.';
      END IF;
    ELSE
      RAISE EXCEPTION 'Unsupported Expense recurrence pattern.';
    END IF;
  END IF;

  INSERT INTO public.expense_rules(
    kuri_id,name,description,frequency,amount,active,created_by,
    recurrence_pattern,recurrence_interval,recurrence_start_date,recurrence_end_date
  )
  VALUES(
    target_kuri_id,
    btrim(expense_name),
    nullif(btrim(expense_description),''),
    normalized_frequency,
    expense_amount,
    coalesce(activate_rule,true),
    (SELECT id FROM public.users WHERE id=actor_id),
    CASE
      WHEN normalized_frequency='ONE_TIME'::public.expense_frequency THEN NULL
      ELSE recurrence_pattern_value
    END,
    CASE
      WHEN recurrence_pattern_value IN (
        'WEEKLY'::public.expense_recurrence_pattern,
        'MONTHLY'::public.expense_recurrence_pattern,
        'YEARLY'::public.expense_recurrence_pattern
      )
      THEN coalesce(recurrence_interval_value,1)
      ELSE NULL
    END,
    CASE
      WHEN recurrence_pattern_value IN (
        'WEEKLY'::public.expense_recurrence_pattern,
        'MONTHLY'::public.expense_recurrence_pattern,
        'YEARLY'::public.expense_recurrence_pattern,
        'CUSTOM'::public.expense_recurrence_pattern
      )
      THEN coalesce(recurrence_start_date_value,current_date)
      ELSE NULL
    END,
    CASE
      WHEN recurrence_pattern_value IN (
        'WEEKLY'::public.expense_recurrence_pattern,
        'MONTHLY'::public.expense_recurrence_pattern,
        'YEARLY'::public.expense_recurrence_pattern,
        'CUSTOM'::public.expense_recurrence_pattern
      )
      THEN recurrence_end_date_value
      ELSE NULL
    END
  )
  RETURNING id INTO rule_id;

  IF recurrence_pattern_value='CUSTOM'::public.expense_recurrence_pattern THEN
    FOREACH schedule_date IN ARRAY custom_schedule_dates LOOP
      INSERT INTO public.expense_rule_schedule_dates(expense_rule_id,occurrence_date)
      VALUES(rule_id,schedule_date)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;

  PERFORM public.sync_expense_obligations_for_rule(rule_id);
  RETURN rule_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.generate_expense_obligations_for_rule(
  target_rule_id uuid,
  through_date date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  rule_row record;
  occurrence_row record;
  occurrence_count integer := 0;
  inserted_count integer := 0;
  start_date date;
  end_date date;
  cursor_date date;
  interval_value integer;
BEGIN
  IF target_rule_id IS NULL OR through_date IS NULL THEN
    RAISE EXCEPTION 'Expense rule and generation date are required.';
  END IF;

  SELECT
    er.id,er.kuri_id,er.frequency,er.amount,er.active,
    er.recurrence_pattern,er.recurrence_interval,
    er.recurrence_start_date,er.recurrence_end_date
  INTO rule_row
  FROM public.expense_rules er
  WHERE er.id=target_rule_id;

  IF rule_row.id IS NULL THEN
    RAISE EXCEPTION 'Expense rule not found.';
  END IF;

  IF NOT rule_row.active THEN
    RETURN 0;
  END IF;

  IF rule_row.frequency='ONE_TIME'::public.expense_frequency THEN
    INSERT INTO public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
    )
    SELECT rule_row.id,rule_row.kuri_id,m.id,NULL,NULL,rule_row.amount
    FROM public.memberships m
    WHERE m.kuri_id=rule_row.kuri_id
      AND m.status='ACTIVE'
      AND NOT EXISTS (
        SELECT 1 FROM public.membership_exits me
        WHERE me.membership_id=m.id
          AND me.status IN ('PENDING','APPROVED')
      )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN inserted_count;
  END IF;

  IF rule_row.frequency<>'RECURRING'::public.expense_frequency THEN
    RAISE EXCEPTION 'Unsupported Expense frequency.';
  END IF;

  IF rule_row.recurrence_pattern IS NULL THEN
    RAISE EXCEPTION 'Recurring Expense rule is missing recurrence pattern.';
  END IF;

  IF rule_row.recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern THEN
    INSERT INTO public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
    )
    SELECT rule_row.id,rule_row.kuri_id,m.id,c.id,c.due_date,rule_row.amount
    FROM public.memberships m
    JOIN public.cycles c ON c.kuri_id=m.kuri_id
    WHERE m.kuri_id=rule_row.kuri_id
      AND m.status='ACTIVE'
      AND c.status NOT IN ('COMPLETED','CANCELLED')
      AND c.due_date<=through_date
      AND (rule_row.recurrence_start_date IS NULL OR c.due_date>=rule_row.recurrence_start_date)
      AND (rule_row.recurrence_end_date IS NULL OR c.due_date<=rule_row.recurrence_end_date)
      AND NOT EXISTS (
        SELECT 1 FROM public.membership_exits me
        WHERE me.membership_id=m.id
          AND me.status IN ('PENDING','APPROVED')
      )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN inserted_count;
  END IF;

  start_date := coalesce(rule_row.recurrence_start_date,current_date);
  IF start_date>through_date THEN RETURN 0; END IF;

  end_date := least(
    through_date,
    coalesce(rule_row.recurrence_end_date,through_date)
  );

  interval_value := coalesce(rule_row.recurrence_interval,1);
  IF interval_value<=0 THEN
    RAISE EXCEPTION 'Recurrence interval must be greater than zero.';
  END IF;

  IF rule_row.recurrence_pattern='CUSTOM'::public.expense_recurrence_pattern THEN
    FOR occurrence_row IN
      SELECT ersd.occurrence_date
      FROM public.expense_rule_schedule_dates ersd
      WHERE ersd.expense_rule_id=rule_row.id
        AND ersd.occurrence_date BETWEEN start_date AND end_date
      ORDER BY ersd.occurrence_date
    LOOP
      INSERT INTO public.expense_obligations(
        expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
      )
      SELECT rule_row.id,rule_row.kuri_id,m.id,NULL,
        occurrence_row.occurrence_date,rule_row.amount
      FROM public.memberships m
      WHERE m.kuri_id=rule_row.kuri_id
        AND m.status='ACTIVE'
        AND NOT EXISTS (
          SELECT 1 FROM public.membership_exits me
          WHERE me.membership_id=m.id
            AND me.status IN ('PENDING','APPROVED')
        )
      ON CONFLICT DO NOTHING;

      GET DIAGNOSTICS inserted_count = ROW_COUNT;
      occurrence_count := occurrence_count + inserted_count;
    END LOOP;

    RETURN occurrence_count;
  END IF;

  cursor_date := start_date;
  WHILE cursor_date<=end_date LOOP
    INSERT INTO public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,occurrence_date,amount
    )
    SELECT rule_row.id,rule_row.kuri_id,m.id,NULL,cursor_date,rule_row.amount
    FROM public.memberships m
    WHERE m.kuri_id=rule_row.kuri_id
      AND m.status='ACTIVE'
      AND NOT EXISTS (
        SELECT 1 FROM public.membership_exits me
        WHERE me.membership_id=m.id
          AND me.status IN ('PENDING','APPROVED')
      )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    occurrence_count := occurrence_count + inserted_count;

    cursor_date := CASE rule_row.recurrence_pattern
      WHEN 'WEEKLY'::public.expense_recurrence_pattern
        THEN (cursor_date + make_interval(weeks => interval_value))::date
      WHEN 'MONTHLY'::public.expense_recurrence_pattern
        THEN (cursor_date + make_interval(months => interval_value))::date
      WHEN 'YEARLY'::public.expense_recurrence_pattern
        THEN (cursor_date + make_interval(years => interval_value))::date
    END;
  END LOOP;

  RETURN occurrence_count;
END
$function$;

CREATE OR REPLACE FUNCTION public.generate_expense_obligations_for_membership_rule(
  target_rule_id uuid,
  target_membership_id uuid,
  through_date date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  rule_row public.expense_rules%rowtype;
  schedule_row record;
  occurrence date;
  start_date date;
  end_date date;
  interval_value integer;
  occurrence_count integer := 0;
  inserted_count integer := 0;
BEGIN
  SELECT *
    INTO rule_row
  FROM public.expense_rules
  WHERE id=target_rule_id
    AND active;

  IF NOT FOUND OR target_membership_id IS NULL OR through_date IS NULL THEN
    RETURN 0;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.memberships m
    WHERE m.id=target_membership_id
      AND m.kuri_id=rule_row.kuri_id
      AND m.status='ACTIVE'
      AND NOT EXISTS (
        SELECT 1 FROM public.membership_exits me
        WHERE me.membership_id=m.id
          AND me.status IN ('PENDING','APPROVED')
      )
  ) THEN
    RETURN 0;
  END IF;

  IF rule_row.frequency='ONE_TIME'::public.expense_frequency THEN
    INSERT INTO public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
    )
    VALUES(rule_row.id,rule_row.kuri_id,target_membership_id,NULL,rule_row.amount,NULL)
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN inserted_count;
  END IF;

  IF rule_row.frequency<>'RECURRING'::public.expense_frequency THEN
    RAISE EXCEPTION 'Unsupported Expense frequency.';
  END IF;

  IF rule_row.recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern THEN
    INSERT INTO public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
    )
    SELECT rule_row.id,rule_row.kuri_id,target_membership_id,c.id,rule_row.amount,c.due_date
    FROM public.cycles c
    WHERE c.kuri_id=rule_row.kuri_id
      AND c.status NOT IN ('COMPLETED','CANCELLED')
      AND c.due_date<=through_date
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    RETURN inserted_count;
  END IF;

  start_date := coalesce(rule_row.recurrence_start_date,current_date);
  end_date := least(through_date,coalesce(rule_row.recurrence_end_date,through_date));
  interval_value := greatest(coalesce(rule_row.recurrence_interval,1),1);

  IF start_date>end_date THEN RETURN 0; END IF;

  IF rule_row.recurrence_pattern='CUSTOM'::public.expense_recurrence_pattern THEN
    FOR schedule_row IN
      SELECT occurrence_date
      FROM public.expense_rule_schedule_dates
      WHERE expense_rule_id=rule_row.id
        AND occurrence_date BETWEEN start_date AND end_date
      ORDER BY occurrence_date
    LOOP
      INSERT INTO public.expense_obligations(
        expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
      )
      VALUES(
        rule_row.id,rule_row.kuri_id,target_membership_id,NULL,
        rule_row.amount,schedule_row.occurrence_date
      )
      ON CONFLICT DO NOTHING;

      GET DIAGNOSTICS inserted_count = ROW_COUNT;
      occurrence_count := occurrence_count + inserted_count;
    END LOOP;
    RETURN occurrence_count;
  END IF;

  occurrence := start_date;

  WHILE occurrence<=end_date LOOP
    INSERT INTO public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,occurrence_date
    )
    VALUES(
      rule_row.id,rule_row.kuri_id,target_membership_id,NULL,
      rule_row.amount,occurrence
    )
    ON CONFLICT DO NOTHING;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    occurrence_count := occurrence_count + inserted_count;

    CASE rule_row.recurrence_pattern
      WHEN 'WEEKLY'::public.expense_recurrence_pattern THEN
        occurrence := (occurrence + make_interval(days => 7 * interval_value))::date;
      WHEN 'MONTHLY'::public.expense_recurrence_pattern THEN
        occurrence := (occurrence + make_interval(months => interval_value))::date;
      WHEN 'YEARLY'::public.expense_recurrence_pattern THEN
        occurrence := (occurrence + make_interval(years => interval_value))::date;
      ELSE
        RAISE EXCEPTION 'Unsupported Expense recurrence pattern: %',rule_row.recurrence_pattern;
    END CASE;
  END LOOP;

  RETURN occurrence_count;
END
$function$;

REVOKE ALL ON FUNCTION public.create_expense_rule_for_admin(
  uuid,text,text,public.expense_frequency,bigint,boolean
) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.create_expense_rule_for_admin(
  uuid,text,text,public.expense_frequency,bigint,public.expense_recurrence_pattern,
  integer,date,date,date[],boolean
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_expense_rule_for_admin(
  uuid,text,text,public.expense_frequency,bigint,boolean
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.create_expense_rule_for_admin(
  uuid,text,text,public.expense_frequency,bigint,public.expense_recurrence_pattern,
  integer,date,date,date[],boolean
) TO authenticated;

REVOKE ALL ON FUNCTION public.generate_expense_obligations_for_rule(uuid,date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_expense_obligations_for_membership_rule(uuid,uuid,date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_expense_obligations_for_rule(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_expense_obligations_for_membership(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.sync_expense_obligations_for_kuri(uuid) FROM PUBLIC;
