-- Canonicalize Kuri creation onto the Expense rule model while preserving
-- the existing schedule-aware Kuri creation contract.
--
-- This is deliberately additive/replacement-only:
-- legacy Muppu data is handled by the existing Expense/Muppu bridge and is
-- not backfilled again here.

BEGIN;

DROP FUNCTION IF EXISTS public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,
  text,public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode
);

CREATE FUNCTION public.create_kuri_for_admin(
  name text,
  description text,
  start_date date,
  number_of_cycles integer,
  membership_limit integer,
  installment_amount bigint,
  due_day integer,
  draw_day integer,
  gross_prize_amount bigint,
  expense_amount bigint,
  winner_rule text,
  exit_refund_rule public.refund_policy,
  frequency_value public.kuri_frequency,
  schedule_mode_value public.kuri_schedule_mode
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  organization_id uuid;
  kuri_id uuid;
  actor_user_id uuid := auth.uid();
  admin_org_count integer;
  max_day integer;
  expense_rule_id uuid;
BEGIN
  IF actor_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF frequency_value IS NULL OR schedule_mode_value IS NULL THEN
    RAISE EXCEPTION 'Frequency and schedule mode are required.';
  END IF;

  max_day := CASE
    WHEN schedule_mode_value='CUSTOM'::public.kuri_schedule_mode THEN 31
    WHEN frequency_value='WEEKLY'::public.kuri_frequency THEN 7
    ELSE 31
  END;

  IF nullif(btrim(name),'') IS NULL
     OR start_date IS NULL
     OR number_of_cycles IS NULL OR number_of_cycles <= 0
     OR membership_limit IS NULL OR membership_limit < 1 OR membership_limit > 1000
     OR installment_amount IS NULL OR installment_amount < 0
     OR due_day IS NULL OR due_day < 1 OR due_day > max_day
     OR draw_day IS NULL OR draw_day < 1 OR draw_day > max_day
     OR gross_prize_amount IS NULL OR gross_prize_amount < 0
     OR expense_amount IS NULL OR expense_amount < 0
  THEN
    RAISE EXCEPTION 'Please enter valid Kuri details.';
  END IF;

  SELECT count(DISTINCT ou.organization_id)
    INTO admin_org_count
  FROM public.organization_users ou
  WHERE ou.user_id=actor_user_id
    AND ou.role=ANY(ARRAY['MAIN_ADMIN','ADMIN']::public.app_role[]);

  IF admin_org_count=0 THEN
    RAISE EXCEPTION 'You do not have permission to create a Kuri.';
  ELSIF admin_org_count>1 THEN
    RAISE EXCEPTION 'Organization context is required to create a Kuri.';
  END IF;

  SELECT ou.organization_id
    INTO organization_id
  FROM public.organization_users ou
  WHERE ou.user_id=actor_user_id
    AND ou.role=ANY(ARRAY['MAIN_ADMIN','ADMIN']::public.app_role[])
  ORDER BY ou.organization_id::text
  LIMIT 1;

  INSERT INTO public.kuris(
    organization_id,name,description,start_date,number_of_cycles,
    membership_limit,installment_amount,frequency,schedule_mode,
    due_day,draw_day,gross_prize_amount,muppu_amount,winner_rule,
    exit_refund_rule,created_by
  )
  VALUES(
    organization_id,
    btrim(name),
    nullif(btrim(description),''),
    start_date,
    number_of_cycles,
    membership_limit,
    installment_amount,
    frequency_value,
    schedule_mode_value,
    due_day,
    draw_day,
    gross_prize_amount,
    0,
    coalesce(nullif(btrim(winner_rule),''),'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_rule,'AT_MATURITY'::public.refund_policy),
    actor_user_id
  )
  RETURNING id INTO kuri_id;

  INSERT INTO public.kuri_admins(kuri_id,user_id,role)
  VALUES(kuri_id,actor_user_id,'MAIN_ADMIN');

  IF expense_amount > 0 THEN
    INSERT INTO public.expense_rules(
      kuri_id,name,description,frequency,amount,active,created_by,recurrence_pattern
    )
    VALUES(
      kuri_id,
      'Prize Expense',
      'Default one-time Expense applied to a membership when applicable to settlement or prize deduction.',
      'ONE_TIME'::public.expense_frequency,
      expense_amount,
      true,
      (SELECT u.id FROM public.users u WHERE u.id=actor_user_id),
      NULL
    )
    RETURNING id INTO expense_rule_id;

    PERFORM public.sync_expense_obligations_for_rule(expense_rule_id);
  END IF;

  RETURN kuri_id;
END
$function$;

REVOKE ALL ON FUNCTION public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,
  text,public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.create_kuri_for_admin(
  text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,
  public.refund_policy,public.kuri_frequency,public.kuri_schedule_mode
) TO authenticated;

COMMIT;
