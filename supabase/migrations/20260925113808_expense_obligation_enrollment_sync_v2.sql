BEGIN;

CREATE OR REPLACE FUNCTION public.sync_expense_obligations_for_membership(target_membership_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  target_kuri_id uuid;
  rule_row record;
BEGIN
  SELECT m.kuri_id INTO target_kuri_id
  FROM public.memberships m
  WHERE m.id=target_membership_id AND m.status='ACTIVE';

  IF target_kuri_id IS NULL THEN RETURN; END IF;

  FOR rule_row IN
    SELECT er.id,er.frequency,er.amount
    FROM public.expense_rules er
    WHERE er.kuri_id=target_kuri_id AND er.active
    ORDER BY er.id
  LOOP
    IF rule_row.frequency='ONE_TIME' THEN
      INSERT INTO public.expense_obligations(
        expense_rule_id,kuri_id,membership_id,cycle_id,amount
      )
      VALUES(rule_row.id,target_kuri_id,target_membership_id,NULL,rule_row.amount)
      ON CONFLICT DO NOTHING;
    ELSE
      INSERT INTO public.expense_obligations(
        expense_rule_id,kuri_id,membership_id,cycle_id,amount
      )
      SELECT rule_row.id,target_kuri_id,target_membership_id,c.id,rule_row.amount
      FROM public.cycles c
      WHERE c.kuri_id=target_kuri_id
        AND c.status NOT IN ('COMPLETED','CANCELLED')
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;
END
$function$;

CREATE OR REPLACE FUNCTION public.sync_expense_obligations_for_kuri(target_kuri_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE rule_row record;
BEGIN
  FOR rule_row IN
    SELECT er.id FROM public.expense_rules er
    WHERE er.kuri_id=target_kuri_id AND er.active
    ORDER BY er.id
  LOOP
    PERFORM public.sync_expense_obligations_for_rule(rule_row.id);
  END LOOP;
END
$function$;

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.create_membership_for_admin(uuid,uuid,text)'::regprocedure
  ) INTO v_def;

  IF position('sync_expense_obligations_for_membership' in v_def)=0 THEN
    v_def := replace(
      v_def,
      '  RETURN membership_id_value;',
      '  PERFORM public.sync_expense_obligations_for_membership(membership_id_value);' || E'\n\n' ||
      '  RETURN membership_id_value;'
    );
    EXECUTE v_def;
  END IF;
END
$$;

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.transition_membership_status_for_admin(uuid,public.membership_status)'::regprocedure
  ) INTO v_def;

  IF position('sync_expense_obligations_for_membership(target_membership_id)' in v_def)=0 THEN
    v_def := replace(
      v_def,
      '  RETURN target_status;',
      '  IF target_status=''ACTIVE'' THEN' || E'\n' ||
      '    PERFORM public.sync_expense_obligations_for_membership(target_membership_id);' || E'\n' ||
      '  END IF;' || E'\n\n' ||
      '  RETURN target_status;'
    );
    EXECUTE v_def;
  END IF;
END
$$;

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.generate_cycles_for_admin(uuid)'::regprocedure
  ) INTO v_def;

  IF position('sync_expense_obligations_for_kuri(target_kuri_id)' in v_def)=0 THEN
    v_def := replace(
      v_def,
      '  RETURN v_inserted_cycles;',
      '  PERFORM public.sync_expense_obligations_for_kuri(target_kuri_id);' || E'\n\n' ||
      '  RETURN v_inserted_cycles;'
    );
    EXECUTE v_def;
  END IF;
END
$$;

DO $$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.generate_kuri_schedule_for_admin(uuid)'::regprocedure
  ) INTO v_def;

  IF position('sync_expense_obligations_for_kuri(target_kuri_id)' in v_def)=0 THEN
    v_def := replace(
      v_def,
      '  RETURN created_cycles;',
      '  PERFORM public.sync_expense_obligations_for_kuri(target_kuri_id);' || E'\n\n' ||
      '  RETURN created_cycles;'
    );
    EXECUTE v_def;
  END IF;
END
$$;

REVOKE ALL ON FUNCTION public.sync_expense_obligations_for_membership(uuid) FROM anon,authenticated,public;
REVOKE ALL ON FUNCTION public.sync_expense_obligations_for_kuri(uuid) FROM anon,authenticated,public;

COMMIT;
