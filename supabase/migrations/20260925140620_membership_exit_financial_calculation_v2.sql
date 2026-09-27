-- Exit settlement calculation using effective payment/allocation values and death/request cutoffs.
CREATE OR REPLACE FUNCTION public.calculate_membership_exit_financials(target_exit_id uuid)
RETURNS TABLE(
  exit_id uuid,membership_id uuid,kuri_id uuid,original_person_id uuid,current_holder_person_id uuid,membership_number text,
  exit_reason public.settlement_reason,request_cutoff timestamptz,death_cutoff date,contributed_amount bigint,
  unallocated_payment_amount bigint,outstanding_installment_amount bigint,unpaid_expense_amount bigint,
  unpaid_muppu_amount bigint,pending_prize_amount bigint,has_prior_win boolean,settlement_amount bigint
)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path TO 'public'
AS $$
WITH base AS (
  SELECT me.id exit_id,me.membership_id,m.kuri_id,m.person_id original_person_id,
         coalesce(m.current_holder_person_id,m.person_id) current_holder_person_id,m.membership_number,
         me.reason,me.requested_at,me.exit_date,me.death_date_verified_at
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id WHERE me.id=target_exit_id
),
payment_alloc AS (
  SELECT pa.payment_id,pa.installment_id,coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)::bigint allocated_amount
  FROM public.payment_allocations pa GROUP BY pa.payment_id,pa.installment_id
),
payment_alloc_totals AS (
  SELECT payment_id,coalesce(sum(allocated_amount),0)::bigint allocated_amount FROM payment_alloc GROUP BY payment_id
),
payment_summary AS (
  SELECT p.id,p.kuri_id,p.person_id,p.status,p.payment_date,public.get_effective_payment_amount(p.id)::bigint effective_amount,
         greatest(public.get_effective_payment_amount(p.id)-coalesce(pat.allocated_amount,0),0)::bigint residual_amount
  FROM public.payments p LEFT JOIN payment_alloc_totals pat ON pat.payment_id=p.id
),
contrib AS (
  SELECT b.exit_id,coalesce(sum(pa.allocated_amount),0)::bigint allocated_amount
  FROM base b JOIN public.installments i ON i.membership_id=b.membership_id
  JOIN payment_alloc pa ON pa.installment_id=i.id JOIN payment_summary ps ON ps.id=pa.payment_id AND ps.status='APPROVED'
  GROUP BY b.exit_id
),
all_unallocated AS (
  SELECT b.exit_id,coalesce(sum(ps.residual_amount),0)::bigint unallocated_amount
  FROM base b JOIN payment_summary ps ON ps.kuri_id=b.kuri_id
  AND ps.person_id IN (b.original_person_id,b.current_holder_person_id) AND ps.status='APPROVED'
  AND (b.reason<>'DEATH' OR b.death_date_verified_at IS NULL OR ps.payment_date::date<=b.exit_date)
  GROUP BY b.exit_id
),
expenses AS (
  SELECT b.exit_id,coalesce(sum(CASE WHEN eo.status='UNPAID' AND (
    (b.reason='DEATH' AND b.death_date_verified_at IS NOT NULL AND eo.created_at::date<=b.exit_date)
    OR (b.reason<>'DEATH' AND eo.created_at<=coalesce(b.requested_at,b.exit_date::timestamp))
  ) THEN eo.amount ELSE 0 END),0)::bigint amount
  FROM base b LEFT JOIN public.expense_obligations eo ON eo.membership_id=b.membership_id GROUP BY b.exit_id
),
muppu AS (
  SELECT b.exit_id,coalesce(sum(CASE WHEN mr.status='UNPAID' AND (
    (b.reason='DEATH' AND b.death_date_verified_at IS NOT NULL AND mr.created_at::date<=b.exit_date)
    OR (b.reason<>'DEATH' AND mr.created_at<=coalesce(b.requested_at,b.exit_date::timestamp))
  ) THEN mr.amount ELSE 0 END),0)::bigint amount
  FROM base b LEFT JOIN public.muppu_records mr ON mr.kuri_id=b.kuri_id
  AND mr.person_id IN (b.original_person_id,b.current_holder_person_id) GROUP BY b.exit_id
),
winners AS (
  SELECT b.exit_id,coalesce(bool_or(mw.id IS NOT NULL),false) has_win,
         coalesce(sum(CASE WHEN po.status IN ('PENDING','PROCESSING') THEN po.net_amount ELSE 0 END),0)::bigint pending_prize
  FROM base b LEFT JOIN public.monthly_winner_memberships mwm ON mwm.membership_id=b.membership_id
  LEFT JOIN public.monthly_winners mw ON mw.id=mwm.monthly_winner_id
   AND (b.reason<>'DEATH' OR b.death_date_verified_at IS NULL OR mw.finalized_at::date<=b.exit_date)
  LEFT JOIN public.payouts po ON po.monthly_winner_id=mw.id GROUP BY b.exit_id
),
installment_balances AS (
  SELECT i.id,i.membership_id,i.amount_due,least(i.amount_due,coalesce(sum(pa.allocated_amount),0))::bigint effective_paid
  FROM public.installments i LEFT JOIN payment_alloc pa ON pa.installment_id=i.id GROUP BY i.id,i.membership_id,i.amount_due
),
installments AS (
  SELECT b.exit_id,coalesce(sum(greatest(ib.amount_due-ib.effective_paid,0)),0)::bigint outstanding_amount
  FROM base b JOIN installment_balances ib ON ib.membership_id=b.membership_id GROUP BY b.exit_id
)
SELECT b.exit_id,b.membership_id,b.kuri_id,b.original_person_id,b.current_holder_person_id,b.membership_number,b.reason,
       coalesce(b.requested_at,b.exit_date::timestamp),
       CASE WHEN b.reason='DEATH' AND b.death_date_verified_at IS NOT NULL THEN b.exit_date ELSE NULL END,
       coalesce(c.allocated_amount,0),coalesce(au.unallocated_amount,0),
       CASE WHEN w.has_win THEN coalesce(ins.outstanding_amount,0) ELSE 0 END,
       coalesce(e.amount,0),coalesce(mu.amount,0),coalesce(w.pending_prize,0),coalesce(w.has_win,false),
       greatest(CASE WHEN coalesce(w.has_win,false)
         THEN coalesce(w.pending_prize,0)+coalesce(au.unallocated_amount,0)-coalesce(ins.outstanding_amount,0)-coalesce(e.amount,0)-coalesce(mu.amount,0)
         ELSE coalesce(c.allocated_amount,0)+coalesce(au.unallocated_amount,0)-coalesce(e.amount,0)-coalesce(mu.amount,0)
       END,0)
FROM base b
LEFT JOIN contrib c ON c.exit_id=b.exit_id LEFT JOIN all_unallocated au ON au.exit_id=b.exit_id
LEFT JOIN expenses e ON e.exit_id=b.exit_id LEFT JOIN muppu mu ON mu.exit_id=b.exit_id
LEFT JOIN winners w ON w.exit_id=b.exit_id LEFT JOIN installments ins ON ins.exit_id=b.exit_id;
$$;
REVOKE ALL ON FUNCTION public.calculate_membership_exit_financials(uuid) FROM PUBLIC,anon,authenticated;