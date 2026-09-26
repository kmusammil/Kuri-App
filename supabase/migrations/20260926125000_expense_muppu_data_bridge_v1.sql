-- Migrate legacy Muppu records into the canonical Expense obligation model.
-- This is a data bridge only: payout/settlement calculation is intentionally unchanged.

DO $$
DECLARE
  v_kuri record;
  v_rule_id uuid;
  v_rule_amount bigint;
BEGIN
  FOR v_kuri IN
    SELECT k.id AS kuri_id,
           greatest(
             coalesce(k.muppu_amount, 0),
             coalesce(max(mr.amount), 0)
           )::bigint AS expense_amount
    FROM public.kuris k
    JOIN public.muppu_records mr ON mr.kuri_id = k.id
    GROUP BY k.id, k.muppu_amount
  LOOP
    v_rule_amount := v_kuri.expense_amount;

    IF v_rule_amount <= 0 THEN
      RAISE EXCEPTION 'Cannot migrate Muppu for Kuri %: expense amount must be greater than zero.', v_kuri.kuri_id;
    END IF;

    SELECT er.id
      INTO v_rule_id
    FROM public.expense_rules er
    WHERE er.kuri_id = v_kuri.kuri_id
      AND lower(er.name) = 'expense'
    FOR UPDATE;

    IF v_rule_id IS NULL THEN
      INSERT INTO public.expense_rules (
        kuri_id,
        name,
        description,
        frequency,
        recurrence_pattern,
        amount,
        active,
        created_by
      )
      VALUES (
        v_kuri.kuri_id,
        'Expense',
        'Canonical Expense rule migrated from the legacy Muppu configuration.',
        'PER_CYCLE',
        'PER_CYCLE',
        v_rule_amount,
        true,
        (SELECT k.created_by FROM public.kuris k WHERE k.id = v_kuri.kuri_id)
      )
      RETURNING id INTO v_rule_id;
    ELSE
      IF NOT EXISTS (
        SELECT 1
        FROM public.expense_rules er
        WHERE er.id = v_rule_id
          AND er.frequency = 'PER_CYCLE'
          AND er.recurrence_pattern = 'PER_CYCLE'
          AND er.amount = v_rule_amount
      ) THEN
        RAISE EXCEPTION 'Kuri % already has an Expense rule named Expense with incompatible configuration.', v_kuri.kuri_id;
      END IF;
    END IF;

    INSERT INTO public.expense_obligations (
      expense_rule_id,
      kuri_id,
      membership_id,
      cycle_id,
      amount,
      status,
      settled_at,
      settled_by,
      settlement_reference,
      deducted_from_payout_id,
      occurrence_date
    )
    SELECT
      v_rule_id,
      mr.kuri_id,
      m.id,
      mr.cycle_id,
      mr.amount,
      CASE mr.status
        WHEN 'UNPAID' THEN 'UNPAID'::public.expense_obligation_status
        WHEN 'PAID' THEN 'PAID'::public.expense_obligation_status
        WHEN 'WAIVED' THEN 'WAIVED'::public.expense_obligation_status
        WHEN 'DEDUCTED' THEN 'DEDUCTED_FROM_PRIZE'::public.expense_obligation_status
      END,
      CASE WHEN mr.status = 'PAID' THEN mr.paid_at ELSE NULL END,
      NULL,
      'LEGACY_MUPPU:' || mr.id::text,
      NULL,
      c.due_date
    FROM public.muppu_records mr
    JOIN public.cycles c ON c.id = mr.cycle_id
    JOIN public.memberships m
      ON m.kuri_id = mr.kuri_id
     AND m.person_id = mr.person_id
    WHERE mr.kuri_id = v_kuri.kuri_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.memberships m2
        WHERE m2.kuri_id = mr.kuri_id
          AND m2.person_id = mr.person_id
          AND m2.id <> m.id
      )
    ON CONFLICT (expense_rule_id, membership_id, occurrence_date)
      WHERE occurrence_date IS NOT NULL
    DO NOTHING;

    IF EXISTS (
      SELECT 1
      FROM public.muppu_records mr
      WHERE mr.kuri_id = v_kuri.kuri_id
        AND NOT EXISTS (
          SELECT 1
          FROM public.memberships m
          WHERE m.kuri_id = mr.kuri_id
            AND m.person_id = mr.person_id
        )
    ) THEN
      RAISE EXCEPTION 'Kuri % has a legacy Muppu record without a matching membership.', v_kuri.kuri_id;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.muppu_records mr
      JOIN public.memberships m
        ON m.kuri_id = mr.kuri_id
       AND m.person_id = mr.person_id
      WHERE mr.kuri_id = v_kuri.kuri_id
      GROUP BY mr.id
      HAVING count(m.id) <> 1
    ) THEN
      RAISE EXCEPTION 'Kuri % has a legacy Muppu record with a non-unique membership mapping.', v_kuri.kuri_id;
    END IF;
  END LOOP;
END
$$;
