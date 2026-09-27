-- Harden canonical Expense identity rules.
-- Supports RECURRING rules, exact winner-membership payout linkage, and a
-- narrowly scoped historical bridge state for immutable payouts that already
-- recorded a legacy deduction inconsistently.

CREATE OR REPLACE FUNCTION public.enforce_expense_obligation_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  rule_kuri_id uuid;
  rule_frequency public.expense_frequency;
  rule_recurrence_pattern public.expense_recurrence_pattern;
  membership_kuri_id uuid;
  cycle_kuri_id uuid;
  payout_kuri_id uuid;
  payout_person_id uuid;
  payout_cycle_id uuid;
  payout_winner_id uuid;
  legacy_muppu_id uuid;
BEGIN
  SELECT
    er.kuri_id,
    er.frequency,
    er.recurrence_pattern
  INTO
    rule_kuri_id,
    rule_frequency,
    rule_recurrence_pattern
  FROM public.expense_rules er
  WHERE er.id=NEW.expense_rule_id;

  IF rule_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Expense rule not found.';
  END IF;

  IF NEW.kuri_id<>rule_kuri_id THEN
    RAISE EXCEPTION 'Expense obligation Kuri does not match its rule.';
  END IF;

  SELECT m.kuri_id
    INTO membership_kuri_id
  FROM public.memberships m
  WHERE m.id=NEW.membership_id;

  IF membership_kuri_id IS NULL OR membership_kuri_id<>NEW.kuri_id THEN
    RAISE EXCEPTION 'Expense obligation membership does not belong to the same Kuri.';
  END IF;

  IF rule_frequency='ONE_TIME'::public.expense_frequency THEN
    IF NEW.cycle_id IS NOT NULL OR NEW.occurrence_date IS NOT NULL THEN
      RAISE EXCEPTION 'One-time Expense obligations cannot have a cycle or occurrence date.';
    END IF;
  ELSIF rule_frequency='RECURRING'::public.expense_frequency THEN
    IF rule_recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern THEN
      IF NEW.cycle_id IS NULL OR NEW.occurrence_date IS NULL THEN
        RAISE EXCEPTION 'Per-cycle Expense obligations require a cycle and occurrence date.';
      END IF;
    ELSE
      IF NEW.cycle_id IS NOT NULL OR NEW.occurrence_date IS NULL THEN
        RAISE EXCEPTION 'Calendar/custom Expense obligations require an occurrence date and no cycle.';
      END IF;
    END IF;
  ELSE
    RAISE EXCEPTION 'Unsupported Expense frequency.';
  END IF;

  IF NEW.cycle_id IS NOT NULL THEN
    SELECT c.kuri_id
      INTO cycle_kuri_id
    FROM public.cycles c
    WHERE c.id=NEW.cycle_id;

    IF cycle_kuri_id IS NULL OR cycle_kuri_id<>NEW.kuri_id THEN
      RAISE EXCEPTION 'Expense obligation cycle does not belong to the same Kuri.';
    END IF;
  END IF;

  IF NEW.status='DEDUCTED_FROM_PRIZE'::public.expense_obligation_status THEN
    IF NEW.deducted_from_payout_id IS NULL THEN
      legacy_muppu_id := NULLIF(
        substring(
          coalesce(NEW.settlement_reference,'')
          from '^LEGACY_MUPPU:([0-9a-fA-F-]{36}); HISTORICAL_PAYOUT_UNCHANGED$'
        ),
        ''
      )::uuid;

      IF legacy_muppu_id IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM public.muppu_records mr
           WHERE mr.id=legacy_muppu_id
             AND mr.kuri_id=NEW.kuri_id
             AND mr.status='DEDUCTED'::public.muppu_status
             AND mr.amount=NEW.amount
         )
      THEN
        RAISE EXCEPTION 'Prize-deducted Expense obligations require a payout.';
      END IF;
    ELSE
      SELECT
        k.id,
        mw.person_id,
        mw.cycle_id,
        mw.id
      INTO
        payout_kuri_id,
        payout_person_id,
        payout_cycle_id,
        payout_winner_id
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

      IF NEW.cycle_id IS NOT NULL AND payout_cycle_id<>NEW.cycle_id THEN
        RAISE EXCEPTION 'Expense payout cycle does not match the Expense obligation cycle.';
      END IF;

      IF NOT EXISTS (
        SELECT 1
        FROM public.monthly_winner_memberships mwm
        WHERE mwm.monthly_winner_id=payout_winner_id
          AND mwm.membership_id=NEW.membership_id
      ) THEN
        RAISE EXCEPTION 'Expense payout winner does not match the Expense obligation membership.';
      END IF;
    END IF;
  ELSE
    IF NEW.deducted_from_payout_id IS NOT NULL THEN
      RAISE EXCEPTION 'Only prize-deducted Expense obligations can reference a payout.';
    END IF;
  END IF;

  RETURN NEW;
END
$function$;
