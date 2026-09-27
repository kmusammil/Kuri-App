BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='expense_frequency'
  ) THEN
    CREATE TYPE public.expense_frequency AS ENUM ('ONE_TIME','PER_CYCLE');
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='expense_obligation_status'
  ) THEN
    CREATE TYPE public.expense_obligation_status AS ENUM (
      'UNPAID','PAID','WAIVED','DEDUCTED_FROM_PRIZE'
    );
  END IF;
END
$$;

CREATE TABLE public.expense_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kuri_id uuid NOT NULL REFERENCES public.kuris(id) ON DELETE RESTRICT,
  name text NOT NULL,
  description text,
  frequency public.expense_frequency NOT NULL,
  amount bigint NOT NULL CHECK (amount > 0),
  active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT expense_rules_name_nonblank CHECK (char_length(btrim(name)) BETWEEN 1 AND 200)
);

CREATE UNIQUE INDEX expense_rules_kuri_name_key
  ON public.expense_rules(kuri_id, lower(name));

CREATE INDEX expense_rules_kuri_active_idx
  ON public.expense_rules(kuri_id, active);

CREATE TABLE public.expense_obligations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  expense_rule_id uuid NOT NULL REFERENCES public.expense_rules(id) ON DELETE RESTRICT,
  kuri_id uuid NOT NULL REFERENCES public.kuris(id) ON DELETE RESTRICT,
  membership_id uuid NOT NULL REFERENCES public.memberships(id) ON DELETE RESTRICT,
  cycle_id uuid REFERENCES public.cycles(id) ON DELETE RESTRICT,
  amount bigint NOT NULL CHECK (amount > 0),
  status public.expense_obligation_status NOT NULL DEFAULT 'UNPAID',
  settled_at timestamptz,
  settled_by uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  settlement_reference text,
  deducted_from_payout_id uuid REFERENCES public.payouts(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT expense_obligations_settlement_shape CHECK (
    (status='UNPAID' AND settled_at IS NULL AND settled_by IS NULL AND deducted_from_payout_id IS NULL)
    OR status<>'UNPAID'
  )
);

CREATE UNIQUE INDEX expense_obligations_one_time_key
  ON public.expense_obligations(expense_rule_id,membership_id)
  WHERE cycle_id IS NULL;

CREATE UNIQUE INDEX expense_obligations_per_cycle_key
  ON public.expense_obligations(expense_rule_id,membership_id,cycle_id)
  WHERE cycle_id IS NOT NULL;

CREATE INDEX expense_obligations_kuri_status_idx
  ON public.expense_obligations(kuri_id,status);

CREATE INDEX expense_obligations_membership_idx
  ON public.expense_obligations(membership_id,status);

CREATE INDEX expense_obligations_cycle_idx
  ON public.expense_obligations(cycle_id,status);

CREATE INDEX expense_obligations_payout_idx
  ON public.expense_obligations(deducted_from_payout_id);

ALTER TABLE public.expense_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_obligations ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.expense_rules FROM anon, authenticated;
REVOKE ALL ON TABLE public.expense_obligations FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.enforce_expense_obligation_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  rule_kuri_id uuid;
  rule_frequency public.expense_frequency;
  membership_kuri_id uuid;
  cycle_kuri_id uuid;
  payout_kuri_id uuid;
  payout_person_id uuid;
BEGIN
  SELECT er.kuri_id, er.frequency INTO rule_kuri_id, rule_frequency
  FROM public.expense_rules er WHERE er.id=NEW.expense_rule_id;

  IF rule_kuri_id IS NULL THEN RAISE EXCEPTION 'Expense rule not found.'; END IF;
  IF NEW.kuri_id<>rule_kuri_id THEN RAISE EXCEPTION 'Expense obligation Kuri does not match its rule.'; END IF;

  SELECT m.kuri_id INTO membership_kuri_id
  FROM public.memberships m WHERE m.id=NEW.membership_id;

  IF membership_kuri_id IS NULL OR membership_kuri_id<>NEW.kuri_id THEN
    RAISE EXCEPTION 'Expense obligation membership does not belong to the same Kuri.';
  END IF;

  IF rule_frequency='ONE_TIME' AND NEW.cycle_id IS NOT NULL THEN
    RAISE EXCEPTION 'One-time expense obligations cannot have a cycle.';
  END IF;
  IF rule_frequency='PER_CYCLE' AND NEW.cycle_id IS NULL THEN
    RAISE EXCEPTION 'Per-cycle expense obligations require a cycle.';
  END IF;

  IF NEW.cycle_id IS NOT NULL THEN
    SELECT c.kuri_id INTO cycle_kuri_id
    FROM public.cycles c WHERE c.id=NEW.cycle_id;
    IF cycle_kuri_id IS NULL OR cycle_kuri_id<>NEW.kuri_id THEN
      RAISE EXCEPTION 'Expense obligation cycle does not belong to the same Kuri.';
    END IF;
  END IF;

  IF NEW.status='DEDUCTED_FROM_PRIZE' THEN
    IF NEW.deducted_from_payout_id IS NULL THEN
      RAISE EXCEPTION 'Prize-deducted expense obligations require a payout.';
    END IF;

    SELECT k.id,mw.person_id INTO payout_kuri_id,payout_person_id
    FROM public.payouts po
    JOIN public.monthly_winners mw ON mw.id=po.monthly_winner_id
    JOIN public.cycles c ON c.id=mw.cycle_id
    JOIN public.kuris k ON k.id=c.kuri_id
    WHERE po.id=NEW.deducted_from_payout_id;

    IF payout_kuri_id IS NULL OR payout_kuri_id<>NEW.kuri_id THEN
      RAISE EXCEPTION 'Expense payout does not belong to the same Kuri.';
    END IF;

    IF payout_person_id<>(SELECT m.person_id FROM public.memberships m WHERE m.id=NEW.membership_id) THEN
      RAISE EXCEPTION 'Expense payout recipient does not match the membership person.';
    END IF;
  ELSE
    IF NEW.deducted_from_payout_id IS NOT NULL THEN
      RAISE EXCEPTION 'Only prize-deducted expense obligations can reference a payout.';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

CREATE TRIGGER expense_obligations_identity_guard
BEFORE INSERT OR UPDATE ON public.expense_obligations
FOR EACH ROW EXECUTE FUNCTION public.enforce_expense_obligation_identity();

CREATE OR REPLACE FUNCTION public.audit_financial_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
declare
  actor_user_id uuid;
  org_id uuid;
  entity_id uuid;
  action_name text;
  old_payload jsonb;
  new_payload jsonb;
begin
  actor_user_id := auth.uid();

  if tg_op='DELETE' then
    entity_id := old.id;
    old_payload := to_jsonb(old);
    new_payload := null;
  else
    entity_id := new.id;
    old_payload := case when tg_op='UPDATE' then to_jsonb(old) else null end;
    new_payload := to_jsonb(new);
  end if;

  action_name := lower(tg_op);

  case tg_table_name
    when 'payments' then
      org_id := coalesce(new.organization_id,old.organization_id);
    when 'payment_allocations' then
      select p.organization_id into org_id
      from public.payments p where p.id=coalesce(new.payment_id,old.payment_id);
    when 'installments' then
      select k.organization_id into org_id
      from public.installments i
      join public.memberships m on m.id=i.membership_id
      join public.kuris k on k.id=m.kuri_id
      where i.id=coalesce(new.id,old.id);
    when 'membership_exits' then
      select k.organization_id into org_id
      from public.membership_exits e
      join public.memberships m on m.id=e.membership_id
      join public.kuris k on k.id=m.kuri_id
      where e.id=coalesce(new.id,old.id);
    when 'membership_exit_refund_transactions' then
      select k.organization_id into org_id
      from public.membership_exit_refund_transactions r
      join public.membership_exits e on e.id=r.membership_exit_id
      join public.memberships m on m.id=e.membership_id
      join public.kuris k on k.id=m.kuri_id
      where r.id=coalesce(new.id,old.id);
    when 'muppu_records' then
      select k.organization_id into org_id
      from public.muppu_records mr
      join public.kuris k on k.id=mr.kuri_id
      where mr.id=coalesce(new.id,old.id);
    when 'expense_rules' then
      select k.organization_id into org_id
      from public.expense_rules er
      join public.kuris k on k.id=er.kuri_id
      where er.id=coalesce(new.id,old.id);
    when 'expense_obligations' then
      select k.organization_id into org_id
      from public.expense_obligations eo
      join public.kuris k on k.id=eo.kuri_id
      where eo.id=coalesce(new.id,old.id);
    when 'payouts' then
      select k.organization_id into org_id
      from public.payouts po
      join public.monthly_winners mw on mw.id=po.monthly_winner_id
      join public.cycles c on c.id=mw.cycle_id
      join public.kuris k on k.id=c.kuri_id
      where po.id=coalesce(new.id,old.id);
    else
      org_id := null;
  end case;

  if org_id is null and actor_user_id is not null then
    select ou.organization_id into org_id
    from public.organization_users ou
    where ou.user_id=actor_user_id
    order by case when ou.role in ('MAIN_ADMIN','ADMIN') then 0 else 1 end, ou.organization_id
    limit 1;
  end if;

  if org_id is null then
    raise exception 'Unable to resolve organization for financial audit event on %.%', tg_table_schema, tg_table_name;
  end if;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  values(
    org_id,actor_user_id,action_name,tg_table_name,entity_id,
    old_payload,new_payload,
    case when actor_user_id is null then 'system' else null end
  );

  return coalesce(new,old);
end;
$function$;

CREATE TRIGGER audit_expense_rules
AFTER INSERT OR UPDATE OR DELETE ON public.expense_rules
FOR EACH ROW EXECUTE FUNCTION public.audit_financial_change();

CREATE TRIGGER audit_expense_obligations
AFTER INSERT OR UPDATE OR DELETE ON public.expense_obligations
FOR EACH ROW EXECUTE FUNCTION public.audit_financial_change();

CREATE OR REPLACE FUNCTION public.sync_expense_obligations_for_rule(target_rule_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  rule_row record;
BEGIN
  SELECT er.id,er.kuri_id,er.frequency,er.amount,er.active INTO rule_row
  FROM public.expense_rules er JOIN public.kuris k ON k.id=er.kuri_id
  WHERE er.id=target_rule_id;

  IF rule_row.id IS NULL OR NOT rule_row.active THEN RETURN; END IF;

  IF rule_row.frequency='ONE_TIME' THEN
    INSERT INTO public.expense_obligations(expense_rule_id,kuri_id,membership_id,cycle_id,amount)
    SELECT rule_row.id,rule_row.kuri_id,m.id,NULL,rule_row.amount
    FROM public.memberships m
    WHERE m.kuri_id=rule_row.kuri_id AND m.status='ACTIVE'
    ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO public.expense_obligations(expense_rule_id,kuri_id,membership_id,cycle_id,amount)
    SELECT rule_row.id,rule_row.kuri_id,m.id,c.id,rule_row.amount
    FROM public.memberships m
    JOIN public.cycles c ON c.kuri_id=m.kuri_id
    WHERE m.kuri_id=rule_row.kuri_id
      AND m.status='ACTIVE'
      AND c.status NOT IN ('COMPLETED','CANCELLED')
    ON CONFLICT DO NOTHING;
  END IF;
END
$function$;

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
SET search_path = 'public'
AS $function$
DECLARE
  actor_id uuid := auth.uid();
  kuri_status_value public.kuri_status;
  rule_id uuid;
BEGIN
  IF actor_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to manage Expenses for this Kuri.';
  END IF;

  SELECT k.status INTO kuri_status_value FROM public.kuris k WHERE k.id=target_kuri_id FOR UPDATE;
  IF kuri_status_value IS NULL THEN RAISE EXCEPTION 'Kuri not found.'; END IF;
  IF kuri_status_value IN ('COMPLETED','ARCHIVED') THEN
    RAISE EXCEPTION 'Expense rules cannot be added to a completed or archived Kuri.';
  END IF;
  IF char_length(btrim(coalesce(expense_name,''))) NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'Expense name must be 1-200 characters.';
  END IF;
  IF expense_amount IS NULL OR expense_amount<=0 THEN
    RAISE EXCEPTION 'Expense amount must be greater than zero.';
  END IF;
  IF expense_frequency_value IS NULL THEN RAISE EXCEPTION 'Expense frequency is required.'; END IF;

  INSERT INTO public.expense_rules(kuri_id,name,description,frequency,amount,active,created_by)
  VALUES(
    target_kuri_id,btrim(expense_name),nullif(btrim(expense_description),''),
    expense_frequency_value,expense_amount,coalesce(activate_rule,true),
    (SELECT id FROM public.users WHERE id=actor_id)
  )
  RETURNING id INTO rule_id;

  PERFORM public.sync_expense_obligations_for_rule(rule_id);
  RETURN rule_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.set_expense_rule_active_for_admin(
  target_rule_id uuid,target_active boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $function$
DECLARE
  target_kuri_id uuid;
  target_status public.kuri_status;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT er.kuri_id,k.status INTO target_kuri_id,target_status
  FROM public.expense_rules er JOIN public.kuris k ON k.id=er.kuri_id
  WHERE er.id=target_rule_id
  FOR UPDATE OF er,k;

  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Expense rule not found.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to manage Expenses for this Kuri.';
  END IF;
  IF target_status IN ('COMPLETED','ARCHIVED') THEN
    RAISE EXCEPTION 'Expense rules cannot be changed on a completed or archived Kuri.';
  END IF;

  UPDATE public.expense_rules
  SET active=coalesce(target_active,false),updated_at=now()
  WHERE id=target_rule_id;

  IF coalesce(target_active,false) THEN
    PERFORM public.sync_expense_obligations_for_rule(target_rule_id);
  END IF;
END
$function$;

CREATE OR REPLACE FUNCTION public.list_expense_rules_for_admin(target_kuri_id uuid)
RETURNS TABLE(
  expense_rule_id uuid,name text,description text,frequency public.expense_frequency,
  amount bigint,active boolean,created_at timestamptz,updated_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='public'
AS $function$
  SELECT er.id,er.name,er.description,er.frequency,er.amount,er.active,er.created_at,er.updated_at
  FROM public.expense_rules er
  WHERE er.kuri_id=target_kuri_id
    AND public.has_kuri_admin_role(target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY er.created_at DESC,er.id;
$function$;

CREATE OR REPLACE FUNCTION public.list_expense_obligations_for_admin(
  target_kuri_id uuid,target_cycle_id uuid DEFAULT NULL
)
RETURNS TABLE(
  expense_obligation_id uuid,expense_rule_id uuid,expense_name text,membership_id uuid,
  membership_number text,person_id uuid,registered_name text,cycle_id uuid,cycle_number integer,
  amount bigint,status public.expense_obligation_status,settled_at timestamptz,
  settlement_reference text,deducted_from_payout_id uuid,created_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='public'
AS $function$
  SELECT eo.id,eo.expense_rule_id,er.name,eo.membership_id,m.membership_number,
         m.person_id,p.registered_name,eo.cycle_id,c.cycle_number,eo.amount,eo.status,
         eo.settled_at,eo.settlement_reference,eo.deducted_from_payout_id,eo.created_at
  FROM public.expense_obligations eo
  JOIN public.expense_rules er ON er.id=eo.expense_rule_id
  JOIN public.memberships m ON m.id=eo.membership_id
  JOIN public.people p ON p.id=m.person_id
  LEFT JOIN public.cycles c ON c.id=eo.cycle_id
  WHERE eo.kuri_id=target_kuri_id
    AND (target_cycle_id IS NULL OR eo.cycle_id=target_cycle_id)
    AND public.has_kuri_admin_role(target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY c.cycle_number NULLS FIRST,m.membership_number,er.name;
$function$;

CREATE OR REPLACE FUNCTION public.mark_expense_obligation_paid_for_admin(
  target_obligation_id uuid,paid_reference text DEFAULT NULL,target_paid_at timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='public'
AS $function$
DECLARE target_kuri_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT eo.kuri_id INTO target_kuri_id FROM public.expense_obligations eo
  WHERE eo.id=target_obligation_id FOR UPDATE;
  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Expense obligation not found.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to settle this Expense.';
  END IF;

  UPDATE public.expense_obligations
  SET status='PAID',settled_at=coalesce(target_paid_at,now()),
      settled_by=(SELECT id FROM public.users WHERE id=auth.uid()),
      settlement_reference=nullif(btrim(paid_reference),''),updated_at=now()
  WHERE id=target_obligation_id AND status='UNPAID';

  IF NOT FOUND THEN RAISE EXCEPTION 'Only unpaid Expense obligations can be marked paid.'; END IF;
END
$function$;

CREATE OR REPLACE FUNCTION public.waive_expense_obligation_for_admin(
  target_obligation_id uuid,waiver_reason text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='public'
AS $function$
DECLARE target_kuri_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF char_length(btrim(coalesce(waiver_reason,'')))<1 THEN
    RAISE EXCEPTION 'Expense waiver reason is required.';
  END IF;

  SELECT eo.kuri_id INTO target_kuri_id FROM public.expense_obligations eo
  WHERE eo.id=target_obligation_id FOR UPDATE;
  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Expense obligation not found.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to settle this Expense.';
  END IF;

  UPDATE public.expense_obligations
  SET status='WAIVED',settled_at=now(),
      settled_by=(SELECT id FROM public.users WHERE id=auth.uid()),
      settlement_reference=btrim(waiver_reason),updated_at=now()
  WHERE id=target_obligation_id AND status='UNPAID';

  IF NOT FOUND THEN RAISE EXCEPTION 'Only unpaid Expense obligations can be waived.'; END IF;
END
$function$;

CREATE OR REPLACE FUNCTION public.deduct_expense_from_prize_for_admin(
  target_obligation_id uuid,target_payout_id uuid,deduction_reference text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path='public'
AS $function$
DECLARE
  target_kuri_id uuid;
  payout_kuri_id uuid;
  payout_person_id uuid;
  obligation_person_id uuid;
  payout_status public.payout_status;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT eo.kuri_id,m.person_id INTO target_kuri_id,obligation_person_id
  FROM public.expense_obligations eo JOIN public.memberships m ON m.id=eo.membership_id
  WHERE eo.id=target_obligation_id FOR UPDATE OF eo;

  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Expense obligation not found.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to settle this Expense.';
  END IF;

  SELECT k.id,mw.person_id,po.status INTO payout_kuri_id,payout_person_id,payout_status
  FROM public.payouts po
  JOIN public.monthly_winners mw ON mw.id=po.monthly_winner_id
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE po.id=target_payout_id
  FOR UPDATE OF po,k;

  IF payout_kuri_id IS NULL OR payout_kuri_id<>target_kuri_id THEN
    RAISE EXCEPTION 'Payout does not belong to the Expense obligation Kuri.';
  END IF;
  IF payout_person_id<>obligation_person_id THEN
    RAISE EXCEPTION 'Payout recipient does not match the Expense obligation person.';
  END IF;
  IF payout_status<>'PENDING' THEN
    RAISE EXCEPTION 'Expense prize deductions are only allowed against a PENDING payout.';
  END IF;

  UPDATE public.expense_obligations
  SET status='DEDUCTED_FROM_PRIZE',settled_at=now(),
      settled_by=(SELECT id FROM public.users WHERE id=auth.uid()),
      settlement_reference=nullif(btrim(deduction_reference),''),
      deducted_from_payout_id=target_payout_id,updated_at=now()
  WHERE id=target_obligation_id AND status='UNPAID';

  IF NOT FOUND THEN RAISE EXCEPTION 'Only unpaid Expense obligations can be deducted from a prize.'; END IF;
END
$function$;

GRANT EXECUTE ON FUNCTION public.create_expense_rule_for_admin(uuid,text,text,public.expense_frequency,bigint,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_expense_rule_active_for_admin(uuid,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_expense_rules_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_expense_obligations_for_admin(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_expense_obligation_paid_for_admin(uuid,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.waive_expense_obligation_for_admin(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_expense_from_prize_for_admin(uuid,uuid,text) TO authenticated;

REVOKE ALL ON FUNCTION public.create_expense_rule_for_admin(uuid,text,text,public.expense_frequency,bigint,boolean) FROM anon,public;
REVOKE ALL ON FUNCTION public.set_expense_rule_active_for_admin(uuid,boolean) FROM anon,public;
REVOKE ALL ON FUNCTION public.list_expense_rules_for_admin(uuid) FROM anon,public;
REVOKE ALL ON FUNCTION public.list_expense_obligations_for_admin(uuid,uuid) FROM anon,public;
REVOKE ALL ON FUNCTION public.mark_expense_obligation_paid_for_admin(uuid,text,timestamptz) FROM anon,public;
REVOKE ALL ON FUNCTION public.waive_expense_obligation_for_admin(uuid,text) FROM anon,public;
REVOKE ALL ON FUNCTION public.deduct_expense_from_prize_for_admin(uuid,uuid,text) FROM anon,public;

REVOKE ALL ON FUNCTION public.sync_expense_obligations_for_rule(uuid) FROM anon,authenticated,public;
REVOKE ALL ON FUNCTION public.enforce_expense_obligation_identity() FROM anon,authenticated,public;

COMMIT;
