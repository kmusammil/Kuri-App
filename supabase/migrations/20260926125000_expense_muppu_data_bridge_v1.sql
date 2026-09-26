-- Migrate legacy Expense/Muppu records into the canonical Expense obligation model.
-- Historical payout rows are immutable and are never rewritten.
--
-- Mapping policy:
--   1. Prefer the unique membership recorded for the same person + cycle in
--      monthly_winner_memberships.
--   2. Otherwise allow a unique Kuri/person membership.
--   3. Abort if neither produces exactly one membership.
--   4. For a legacy DEDUCTED record, link the Expense obligation to the
--      historical payout only when that payout demonstrably already contains
--      the same deduction. Otherwise preserve the legacy state without
--      changing the finalized payout.

DO $$
DECLARE
  v_kuri record;
  v_rule_id uuid;
  v_rule_amount bigint;
  v_mr record;
  v_membership_id uuid;
  v_membership_count integer;
  v_winner_membership_count integer;
  v_payout_id uuid;
BEGIN
  FOR v_kuri IN
    SELECT
      k.id AS kuri_id,
      greatest(
        coalesce(k.muppu_amount,0),
        coalesce(max(mr.amount),0)
      )::bigint AS expense_amount
    FROM public.kuris k
    JOIN public.muppu_records mr ON mr.kuri_id=k.id
    GROUP BY k.id,k.muppu_amount
  LOOP
    v_rule_amount := v_kuri.expense_amount;

    IF v_rule_amount<=0 THEN
      RAISE EXCEPTION
        'Cannot migrate legacy Expense records for Kuri %: expense amount must be greater than zero.',
        v_kuri.kuri_id;
    END IF;

    SELECT er.id
      INTO v_rule_id
    FROM public.expense_rules er
    WHERE er.kuri_id=v_kuri.kuri_id
      AND lower(er.name)='expense'
    FOR UPDATE;

    IF v_rule_id IS NULL THEN
      INSERT INTO public.expense_rules(
        kuri_id,
        name,
        description,
        frequency,
        recurrence_pattern,
        amount,
        active,
        created_by
      )
      VALUES(
        v_kuri.kuri_id,
        'Expense',
        'Canonical Expense rule migrated from the legacy Muppu configuration.',
        'RECURRING'::public.expense_frequency,
        'PER_CYCLE'::public.expense_recurrence_pattern,
        v_rule_amount,
        true,
        (SELECT k.created_by FROM public.kuris k WHERE k.id=v_kuri.kuri_id)
      )
      RETURNING id INTO v_rule_id;
    ELSE
      IF NOT EXISTS(
        SELECT 1
        FROM public.expense_rules er
        WHERE er.id=v_rule_id
          AND er.frequency='RECURRING'::public.expense_frequency
          AND er.recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern
          AND er.amount=v_rule_amount
      ) THEN
        RAISE EXCEPTION
          'Kuri % already has an Expense rule named Expense with incompatible configuration.',
          v_kuri.kuri_id;
      END IF;
    END IF;

    FOR v_mr IN
      SELECT mr.id,mr.kuri_id,mr.cycle_id,mr.person_id,mr.amount,mr.status,
             mr.paid_at,mr.payment_reference,mr.created_at,
             c.due_date
      FROM public.muppu_records mr
      JOIN public.cycles c ON c.id=mr.cycle_id
      WHERE mr.kuri_id=v_kuri.kuri_id
      ORDER BY mr.created_at,mr.id
    LOOP
      v_membership_id := NULL;
      v_payout_id := NULL;

      SELECT count(*)
        INTO v_membership_count
      FROM public.memberships m
      WHERE m.kuri_id=v_mr.kuri_id
        AND m.person_id=v_mr.person_id;

      SELECT count(*)
        INTO v_winner_membership_count
      FROM public.monthly_winners mw
      JOIN public.monthly_winner_memberships mwm
        ON mwm.monthly_winner_id=mw.id
      JOIN public.memberships m
        ON m.id=mwm.membership_id
      WHERE mw.cycle_id=v_mr.cycle_id
        AND mw.person_id=v_mr.person_id
        AND m.kuri_id=v_mr.kuri_id
        AND m.person_id=v_mr.person_id;

      IF v_winner_membership_count=1 THEN
        SELECT m.id
          INTO v_membership_id
        FROM public.monthly_winners mw
        JOIN public.monthly_winner_memberships mwm
          ON mwm.monthly_winner_id=mw.id
        JOIN public.memberships m
          ON m.id=mwm.membership_id
        WHERE mw.cycle_id=v_mr.cycle_id
          AND mw.person_id=v_mr.person_id
          AND m.kuri_id=v_mr.kuri_id
          AND m.person_id=v_mr.person_id
        LIMIT 1;
      ELSIF v_winner_membership_count=0 AND v_membership_count=1 THEN
        SELECT m.id
          INTO v_membership_id
        FROM public.memberships m
        WHERE m.kuri_id=v_mr.kuri_id
          AND m.person_id=v_mr.person_id
        LIMIT 1;
      ELSE
        RAISE EXCEPTION
          'Legacy Expense record % cannot be mapped uniquely: memberships=%, winning_memberships=%.',
          v_mr.id,v_membership_count,v_winner_membership_count;
      END IF;

      IF v_membership_id IS NULL THEN
        RAISE EXCEPTION
          'Legacy Expense record % could not be mapped to a membership.',
          v_mr.id;
      END IF;

      IF v_mr.status='DEDUCTED' THEN
        SELECT po.id
          INTO v_payout_id
        FROM public.monthly_winners mw
        JOIN public.payouts po
          ON po.monthly_winner_id=mw.id
        WHERE mw.cycle_id=v_mr.cycle_id
          AND mw.person_id=v_mr.person_id
          AND po.muppu_amount=v_mr.amount
          AND po.net_amount=
            greatest(
              po.gross_amount
              -po.muppu_amount
              -coalesce(po.expense_deductions,0)
              -coalesce(po.other_deductions,0),
              0
            )
        ORDER BY po.created_at DESC
        LIMIT 1;
      END IF;

      INSERT INTO public.expense_obligations(
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
      VALUES(
        v_rule_id,
        v_mr.kuri_id,
        v_membership_id,
        v_mr.cycle_id,
        v_mr.amount,
        CASE v_mr.status
          WHEN 'UNPAID' THEN 'UNPAID'::public.expense_obligation_status
          WHEN 'PAID' THEN 'PAID'::public.expense_obligation_status
          WHEN 'WAIVED' THEN 'WAIVED'::public.expense_obligation_status
          WHEN 'DEDUCTED' THEN 'DEDUCTED_FROM_PRIZE'::public.expense_obligation_status
        END,
        CASE
          WHEN v_mr.status='PAID'
            THEN coalesce(v_mr.paid_at,v_mr.created_at)
          WHEN v_mr.status IN ('WAIVED','DEDUCTED')
            THEN v_mr.created_at
          ELSE NULL
        END,
        NULL,
        CASE
          WHEN v_mr.status='DEDUCTED' AND v_payout_id IS NOT NULL
            THEN 'LEGACY_MUPPU:'||v_mr.id::text||'; HISTORICAL_PAYOUT:'||v_payout_id::text
          WHEN v_mr.status='DEDUCTED'
            THEN 'LEGACY_MUPPU:'||v_mr.id::text||'; HISTORICAL_PAYOUT_UNCHANGED'
          ELSE
            'LEGACY_MUPPU:'||v_mr.id::text
        END,
        CASE
          WHEN v_mr.status='DEDUCTED' THEN v_payout_id
          ELSE NULL
        END,
        v_mr.due_date
      )
      ON CONFLICT(
        expense_rule_id,
        membership_id,
        occurrence_date
      ) WHERE occurrence_date IS NOT NULL
      DO NOTHING;
    END LOOP;
  END LOOP;
END
$$;
