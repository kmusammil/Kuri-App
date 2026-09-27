BEGIN;

CREATE OR REPLACE FUNCTION public.create_kuri_for_admin(name text, description text DEFAULT NULL::text, start_date date DEFAULT NULL::date, number_of_cycles integer DEFAULT NULL::integer, membership_limit integer DEFAULT NULL::integer, installment_amount bigint DEFAULT NULL::bigint, due_day integer DEFAULT NULL::integer, draw_day integer DEFAULT NULL::integer, gross_prize_amount bigint DEFAULT NULL::bigint, muppu_amount bigint DEFAULT 0, winner_rule text DEFAULT 'ALL_PERSON_MEMBERSHIPS'::text, exit_refund_rule refund_policy DEFAULT 'AT_MATURITY'::refund_policy)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  organization_id uuid;
  kuri_id uuid;
  admin_org_count integer;
BEGIN
  IF (SELECT auth.uid()) IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  -- Count distinct organizations rather than aggregating UUIDs with min(uuid).
  SELECT count(DISTINCT ou.organization_id)
    INTO admin_org_count
  FROM public.organization_users ou
  WHERE ou.user_id=(SELECT auth.uid())
    AND ou.role=ANY(ARRAY['MAIN_ADMIN','ADMIN']::public.app_role[]);

  IF admin_org_count=0 THEN
    RAISE EXCEPTION 'You do not have permission to create a Kuri.';
  ELSIF admin_org_count>1 THEN
    RAISE EXCEPTION 'Organization context is required to create a Kuri.';
  END IF;

  SELECT ou.organization_id
    INTO organization_id
  FROM public.organization_users ou
  WHERE ou.user_id=(SELECT auth.uid())
    AND ou.role=ANY(ARRAY['MAIN_ADMIN','ADMIN']::public.app_role[])
  ORDER BY ou.organization_id::text
  LIMIT 1;

  IF nullif(trim(name), '') IS NULL
    OR start_date IS NULL
    OR number_of_cycles IS NULL OR number_of_cycles<=0
    OR membership_limit IS NULL OR membership_limit<=0
    OR installment_amount IS NULL OR installment_amount<0
    OR due_day IS NULL OR due_day<1 OR due_day>31
    OR draw_day IS NULL OR draw_day<1 OR draw_day>31
    OR gross_prize_amount IS NULL OR gross_prize_amount<0
    OR muppu_amount IS NULL OR muppu_amount<0 THEN
    RAISE EXCEPTION 'Please enter valid Kuri details.';
  END IF;

  INSERT INTO public.kuris(
    organization_id,name,description,start_date,number_of_cycles,
    membership_limit,installment_amount,frequency,due_day,draw_day,
    gross_prize_amount,muppu_amount,winner_rule,exit_refund_rule,created_by
  )
  VALUES(
    organization_id,
    trim(name),
    nullif(trim(description),''),
    start_date,
    number_of_cycles,
    membership_limit,
    installment_amount,
    'MONTHLY',
    due_day,
    draw_day,
    gross_prize_amount,
    muppu_amount,
    coalesce(nullif(trim(winner_rule),''),'ALL_PERSON_MEMBERSHIPS'),
    coalesce(exit_refund_policy,'AT_MATURITY'),
    (SELECT auth.uid())
  )
  RETURNING id INTO kuri_id;

  INSERT INTO public.kuri_admins(kuri_id,user_id,role)
  VALUES(kuri_id,(SELECT auth.uid()),'MAIN_ADMIN');

  RETURN kuri_id;
END;
$function$


REVOKE ALL ON FUNCTION public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_kuri_for_admin(text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,public.refund_policy) TO authenticated;

COMMIT;