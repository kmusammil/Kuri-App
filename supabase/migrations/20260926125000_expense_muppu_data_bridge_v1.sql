-- Migrate legacy Expense/Muppu records into the canonical Expense model.
-- Historical payout rows are immutable and are never rewritten.
--
-- Mapping policy:
--   * Prefer the membership explicitly recorded in monthly_winner_memberships for
--     the same person + cycle when the legacy record has a corresponding winner.
--   * Otherwise allow a unique Kuri/person membership.
--   * If neither produces exactly one membership, abort safely.
--   * A historical DEDUCTED record is linked to its payout only when the existing
--     payout demonstrably already contains that deduction. Otherwise its legacy
--     status is preserved without mutating the finalized payout.

DO $$
DECLARE
  v_kuri record;
  v_rule_id uuid;
  v_rule_amount bigint;
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

    FOR v_membership_id, v_payout_id IN
      SELECT
        m.id,
        CASE
          WHEN mr.status='DEDUCTED'
               AND po.status IN ('PENDING','PROCESSING','PAID')
               AND po.muppu_amount=mr.amount
               AND po.net_amount=
                   greatest(
                     po.gross_amount
                     -po.muppu_amount
                     -coalesce(po.expense_deductions,0)
                     -coalesce(po.other_deductions,0),
                     0
                   )
          THEN po.id
          ELSE NULL
        END
      FROM public.muppu_records mr
      JOIN public.cycles c
        ON c.id=mr.cycle_id
      LEFT JOIN LATERAL(
        SELECT mwm.membership_id
        FROM public.monthly_winners mw
        JOIN public.monthly_winner_memberships mwm
          ON mwm.monthly_winner_id=mw.id
        WHERE mw.cycle_id=mr.cycle_id
          AND mw.person_id=mr.person_id
        LIMIT 1
      ) winner_membership ON true
      LEFT JOIN public.membership_exits me
        ON false
      LEFT JOIN public.payouts po
        ON po.monthly_winner_id IN (
          SELECT mw.id
          FROM public.monthly_winners mw
          WHERE mw.cycle_id=mr.cycle_id
            AND mw.person_id=mr.person_id
        )
      JOIN public.memberships m
        ON m.id=winner_membership.membership_id
      WHERE mr.kuri_id=v_kuri.kuri_id
        AND winner_membership.membership_id IS NOT NULL
    LOOP
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
      SELECT
        v_rule_id,
        mr.kuri_id,
        v_membership_id,
        mr.cycle_id,
        mr.amount,
        CASE mr.status
          WHEN 'UNPAID' THEN 'UNPAID'::public.expense_obligation_status
          WHEN 'PAID' THEN 'PAID'::public.expense_obligation_status
          WHEN 'WAIVED' THEN 'WAIVED'::public.expense_obligation_status
          WHEN 'DEDUCTED' THEN 'DEDUCTED_FROM_PRIZE'::public.expense_obligation_status
        END,
        CASE
          WHEN mr.status='PAID' THEN coalesce(mr.paid_at,mr.created_at)
          WHEN mr.status IN ('WAIVED','DEDUCTED') THEN mr.created_at
          ELSE NULL
        END,
        NULL,
        CASE
          WHEN mr.status='DEDUCTED' AND v_payout_id IS NOT NULL
            THEN 'LEGACY_MUPPU:'||mr.id::text||'; HISTORICAL_PAYOUT:'||v_payout_id::text
          WHEN mr.status='DEDUCTED'
            THEN 'LEGACY_MUPPU:'||mr.id::text||'; HISTORICAL_PAYOUT_UNCHANGED'
          ELSE
            'LEGACY_MUPPU:'||mr.id::text
        END,
        CASE
          WHEN mr.status='DEDUCTED' THEN v_payout_id
          ELSE NULL
        END,
        c.due_date
      FROM public.muppu_records mr
      JOIN public.cycles c ON c.id=mr.cycle_id
      WHERE mr.id IN(
        SELECT mr2.id
        FROM public.muppu_records mr2
        WHERE mr2.kuri_id=v_kuri.kuri_id
          AND mr2.cycle_id=c.id
          AND mr2.person_id=(
            SELECT m2.person_id
            FROM public.memberships m2
            WHERE m2.id=v_membership_id
            LIMIT 1
          )
      )
      ORDER BY mr.created_at
      LIMIT 1
      ON CONFLICT(
        expense_rule_id,
        membership_id,
        occurrence_date
      ) WHERE occurrence_date IS NOT NULL
      DO NOTHING;
    END LOOP;

    FOR v_membership_id IN
      SELECT m.id
      FROM public.memberships m
      JOIN public.muppu_records mr
        ON mr.kuri_id=m.kuri_id
       AND mr.person_id=m.person_id
      LEFT JOIN public.monthly_winners mw
        ON mw.cycle_id=mr.cycle_id
       AND mw.person_id=mr.person_id
      LEFT JOIN public.monthly_winner_memberships mwm
        ON mwm.monthly_winner_id=mw.id
       AND mwm.membership_id=m.id
      WHERE m.kuri_id=v_kuri.kuri_id
      GROUP BY m.id
      HAVING count(DISTINCT mr.id)=0
    LOOP
      NULL;
    END LOOP;

    -- Every legacy record must resolve to exactly one membership.
    FOR v_membership_id IN
      SELECT mr.id
      FROM public.muppu_records mr
      WHERE mr.kuri_id=v_kuri.kuri_id
        AND (
          SELECT count(*)
          FROM public.monthly_winners mw
          JOIN public.monthly_winner_memberships mwm
            ON mwm.monthly_winner_id=mw.id
          JOIN public.memberships m
            ON m.id=mwm.membership_id
          WHERE mw.cycle_id=mr.cycle_id
            AND mw.person_id=mr.person_id
            AND m.kuri_id=mr.kuri_id
            AND m.person_id=mr.person_id
        ) + (
          SELECT count(*)
          FROM public.memberships m
          WHERE m.kuri_id=mr.kuri_id
            AND m.person_id=mr.person_id
        ) = 0
    LOOP
      RAISE EXCEPTION
        'Kuri % has legacy Expense record % without any matching membership.',
        v_kuri.kuri_id,v_membership_id;
    END LOOP;
  END LOOP;
END
$$;
