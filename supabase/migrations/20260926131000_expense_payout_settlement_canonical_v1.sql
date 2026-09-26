-- Make payout and exit settlement Expense-only.
-- Existing finalized payouts are never rewritten. New/reused PENDING payouts
-- carry no legacy Muppu component; explicit Expense deductions are authoritative.

CREATE OR REPLACE FUNCTION public.prepare_payout_for_admin(target_winner_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_user_id uuid := auth.uid();
  v_payout_id uuid;
  v_payout_status public.payout_status;
  v_winner_cycle_id uuid;
  v_target_kuri_id uuid;
  v_gross_prize_amount bigint;
  v_payout_muppu_amount bigint := 0;
  v_expense_deduction_amount bigint := 0;
  v_cycle_status public.cycle_status;
BEGIN
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT
    mw.cycle_id,
    k.id,
    k.gross_prize_amount,
    c.status
  INTO
    v_winner_cycle_id,
    v_target_kuri_id,
    v_gross_prize_amount,
    v_cycle_status
  FROM public.monthly_winners mw
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(
      k.id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF mw,k,c;

  IF v_target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Monthly winner not found.';
  END IF;

  IF v_cycle_status<>'COMPLETED' THEN
    RAISE EXCEPTION 'Cycle must be COMPLETED before preparing a payout.';
  END IF;

  IF v_gross_prize_amount<=0 THEN
    RAISE EXCEPTION 'Gross prize amount must be greater than zero.';
  END IF;

  SELECT po.id,po.status
    INTO v_payout_id,v_payout_status
  FROM public.payouts po
  WHERE po.monthly_winner_id=target_winner_id
  FOR UPDATE;

  IF v_payout_id IS NULL THEN
    INSERT INTO public.payouts(
      monthly_winner_id,
      gross_amount,
      muppu_amount,
      expense_deductions,
      other_deductions,
      net_amount,
      status
    )
    VALUES(
      target_winner_id,
      v_gross_prize_amount,
      0,
      0,
      0,
      v_gross_prize_amount,
      'PENDING'
    )
    RETURNING id INTO v_payout_id;
  ELSIF v_payout_status<>'PENDING' THEN
    RETURN v_payout_id;
  END IF;

  SELECT coalesce(sum(eo.amount),0)
    INTO v_expense_deduction_amount
  FROM public.expense_obligations eo
  WHERE eo.deducted_from_payout_id=v_payout_id
    AND eo.status='DEDUCTED_FROM_PRIZE';

  UPDATE public.payouts po
  SET gross_amount=v_gross_prize_amount,
      muppu_amount=v_payout_muppu_amount,
      expense_deductions=v_expense_deduction_amount,
      net_amount=greatest(
        v_gross_prize_amount
        -v_payout_muppu_amount
        -v_expense_deduction_amount
        -po.other_deductions,
        0
      )
  WHERE po.id=v_payout_id
    AND po.status='PENDING';

  RETURN v_payout_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.calculate_membership_exit_financials(target_exit_id uuid)
RETURNS TABLE(
  exit_id uuid,
  membership_id uuid,
  kuri_id uuid,
  original_person_id uuid,
  current_holder_person_id uuid,
  membership_number text,
  exit_reason public.settlement_reason,
  request_cutoff timestamptz,
  death_cutoff date,
  contributed_amount bigint,
  unallocated_payment_amount bigint,
  outstanding_installment_amount bigint,
  unpaid_expense_amount bigint,
  unpaid_muppu_amount bigint,
  pending_prize_amount bigint,
  has_prior_win boolean,
  settlement_amount bigint
)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
WITH base AS (
  SELECT
    me.id exit_id,
    me.membership_id,
    m.kuri_id,
    m.person_id original_person_id,
    coalesce(m.current_holder_person_id,m.person_id) current_holder_person_id,
    m.membership_number,
    me.reason,
    me.requested_at,
    me.exit_date,
    me.death_date_verified_at
  FROM public.membership_exits me
  JOIN public.memberships m ON m.id=me.membership_id
  WHERE me.id=target_exit_id
),
payment_alloc AS (
  SELECT
    pa.payment_id,
    pa.installment_id,
    coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)::bigint allocated_amount
  FROM public.payment_allocations pa
  GROUP BY pa.payment_id,pa.installment_id
),
payment_alloc_totals AS (
  SELECT
    payment_id,
    coalesce(sum(allocated_amount),0)::bigint allocated_amount
  FROM payment_alloc
  GROUP BY payment_id
),
payment_summary AS (
  SELECT
    p.id,
    p.kuri_id,
    p.person_id,
    p.status,
    p.payment_date,
    public.get_effective_payment_amount(p.id)::bigint effective_amount,
    greatest(
      public.get_effective_payment_amount(p.id)
      -coalesce(pat.allocated_amount,0),
      0
    )::bigint residual_amount
  FROM public.payments p
  LEFT JOIN payment_alloc_totals pat ON pat.payment_id=p.id
),
contrib AS (
  SELECT
    b.exit_id,
    coalesce(sum(pa.allocated_amount),0)::bigint allocated_amount
  FROM base b
  JOIN public.installments i ON i.membership_id=b.membership_id
  JOIN payment_alloc pa ON pa.installment_id=i.id
  JOIN payment_summary ps
    ON ps.id=pa.payment_id
   AND ps.status='APPROVED'
  GROUP BY b.exit_id
),
all_unallocated AS (
  SELECT
    b.exit_id,
    coalesce(sum(ps.residual_amount),0)::bigint unallocated_amount
  FROM base b
  JOIN payment_summary ps
    ON ps.kuri_id=b.kuri_id
   AND ps.person_id IN (b.original_person_id,b.current_holder_person_id)
   AND ps.status='APPROVED'
   AND (
     b.reason<>'DEATH'
     OR b.death_date_verified_at IS NULL
     OR ps.payment_date::date<=b.exit_date
   )
  GROUP BY b.exit_id
),
expenses AS (
  SELECT
    b.exit_id,
    coalesce(
      sum(
        CASE
          WHEN eo.status='UNPAID'
           AND (
             (
               b.reason='DEATH'
               AND b.death_date_verified_at IS NOT NULL
               AND coalesce(eo.occurrence_date,eo.created_at::date)<=b.exit_date
             )
             OR
             (
               b.reason<>'DEATH'
               AND coalesce(eo.occurrence_date,eo.created_at::date)
                   <=coalesce(b.requested_at,b.exit_date::timestamp)::date
             )
           )
          THEN eo.amount
          ELSE 0
        END
      ),
      0
    )::bigint amount
  FROM base b
  LEFT JOIN public.expense_obligations eo
    ON eo.membership_id=b.membership_id
  GROUP BY b.exit_id
),
winners AS (
  SELECT
    b.exit_id,
    coalesce(bool_or(mw.id IS NOT NULL),false) has_win,
    coalesce(
      sum(
        CASE
          WHEN mw.id IS NOT NULL
           AND (
             b.reason<>'DEATH'
             OR b.death_date_verified_at IS NULL
             OR mw.finalized_at::date<=b.exit_date
           )
           AND (po.id IS NULL OR po.status IN ('PENDING','PROCESSING'))
          THEN k.gross_prize_amount
          ELSE 0
        END
      ),
      0
    )::bigint pending_prize
  FROM base b
  LEFT JOIN public.monthly_winner_memberships mwm
    ON mwm.membership_id=b.membership_id
  LEFT JOIN public.monthly_winners mw
    ON mw.id=mwm.monthly_winner_id
   AND (
     b.reason<>'DEATH'
     OR b.death_date_verified_at IS NULL
     OR mw.finalized_at::date<=b.exit_date
   )
  LEFT JOIN public.cycles c ON c.id=mw.cycle_id
  LEFT JOIN public.kuris k ON k.id=c.kuri_id
  LEFT JOIN public.payouts po ON po.monthly_winner_id=mw.id
  GROUP BY b.exit_id
),
installment_balances AS (
  SELECT
    i.id,
    i.membership_id,
    i.amount_due,
    least(
      i.amount_due,
      coalesce(sum(pa.allocated_amount),0)
    )::bigint effective_paid
  FROM public.installments i
  LEFT JOIN payment_alloc pa ON pa.installment_id=i.id
  GROUP BY i.id,i.membership_id,i.amount_due
),
installments AS (
  SELECT
    b.exit_id,
    coalesce(
      sum(greatest(ib.amount_due-ib.effective_paid,0)),
      0
    )::bigint outstanding_amount
  FROM base b
  JOIN installment_balances ib
    ON ib.membership_id=b.membership_id
  GROUP BY b.exit_id
)
SELECT
  b.exit_id,
  b.membership_id,
  b.kuri_id,
  b.original_person_id,
  b.current_holder_person_id,
  b.membership_number,
  b.reason,
  coalesce(b.requested_at,b.exit_date::timestamp),
  CASE
    WHEN b.reason='DEATH' AND b.death_date_verified_at IS NOT NULL
    THEN b.exit_date
    ELSE NULL
  END,
  coalesce(c.allocated_amount,0),
  coalesce(au.unallocated_amount,0),
  CASE
    WHEN w.has_win THEN coalesce(ins.outstanding_amount,0)
    ELSE 0
  END,
  coalesce(e.amount,0),
  0::bigint,
  coalesce(w.pending_prize,0),
  coalesce(w.has_win,false),
  greatest(
    CASE
      WHEN coalesce(w.has_win,false)
      THEN
        coalesce(w.pending_prize,0)
        +coalesce(au.unallocated_amount,0)
        -coalesce(ins.outstanding_amount,0)
        -coalesce(e.amount,0)
      ELSE
        coalesce(c.allocated_amount,0)
        +coalesce(au.unallocated_amount,0)
        -coalesce(e.amount,0)
    END,
    0
  )
FROM base b
LEFT JOIN contrib c ON c.exit_id=b.exit_id
LEFT JOIN all_unallocated au ON au.exit_id=b.exit_id
LEFT JOIN expenses e ON e.exit_id=b.exit_id
LEFT JOIN winners w ON w.exit_id=b.exit_id
LEFT JOIN installments ins ON ins.exit_id=b.exit_id;
$function$;
