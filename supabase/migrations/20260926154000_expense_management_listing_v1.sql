-- Expand the canonical Expense admin listing to expose recurrence metadata
-- and Kuri context. The branch already owns the recurrence schema; this only
-- upgrades the read contract.

BEGIN;

DROP FUNCTION IF EXISTS public.list_expense_rules_for_admin(uuid);

CREATE FUNCTION public.list_expense_rules_for_admin(
  target_kuri_id uuid DEFAULT NULL
)
RETURNS TABLE(
  expense_rule_id uuid,
  kuri_id uuid,
  kuri_name text,
  name text,
  description text,
  frequency public.expense_frequency,
  amount bigint,
  active boolean,
  recurrence_pattern public.expense_recurrence_pattern,
  recurrence_interval integer,
  recurrence_start_date date,
  recurrence_end_date date,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = 'public'
AS $function$
  SELECT
    er.id,
    er.kuri_id,
    k.name,
    er.name,
    er.description,
    er.frequency,
    er.amount,
    er.active,
    er.recurrence_pattern,
    er.recurrence_interval,
    er.recurrence_start_date,
    er.recurrence_end_date,
    er.created_at
  FROM public.expense_rules er
  JOIN public.kuris k ON k.id=er.kuri_id
  WHERE (target_kuri_id IS NULL OR er.kuri_id=target_kuri_id)
    AND public.has_kuri_admin_role(
      er.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY k.created_at DESC, er.created_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.list_expense_rules_for_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_expense_rules_for_admin(uuid) TO authenticated;

COMMIT;
