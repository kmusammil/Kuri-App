-- WINNER-008 / death-settlement cutoff hardening
-- Use the verified death date as the financial participation cutoff.
-- Winning obligations remain included for non-death exits.

create or replace function public.calculate_membership_exit_financials(target_exit_id uuid)
returns table(
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
language sql
stable
set search_path to 'public'
as $function$
with base as (
  select
    me.id exit_id,
    me.membership_id,
    m.kuri_id,
    m.person_id original_person_id,
    coalesce(m.current_holder_person_id,m.person_id) current_holder_person_id,
    m.membership_number,
    me.reason,
    me.requested_at,
    me.exit_date,
    me.death_date,
    me.death_date_verified_at
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id
),
payment_alloc as (
  select
    pa.payment_id,
    pa.installment_id,
    coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)::bigint allocated_amount
  from public.payment_allocations pa
  group by pa.payment_id,pa.installment_id
),
payment_alloc_totals as (
  select
    payment_id,
    coalesce(sum(allocated_amount),0)::bigint allocated_amount
  from payment_alloc
  group by payment_id
),
payment_summary as (
  select
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
  from public.payments p
  left join payment_alloc_totals pat on pat.payment_id=p.id
),
contrib as (
  select
    b.exit_id,
    coalesce(sum(pa.allocated_amount),0)::bigint allocated_amount
  from base b
  join public.installments i on i.membership_id=b.membership_id
  join payment_alloc pa on pa.installment_id=i.id
  join payment_summary ps
    on ps.id=pa.payment_id
   and ps.status='APPROVED'
  group by b.exit_id
),
all_unallocated as (
  select
    b.exit_id,
    coalesce(sum(ps.residual_amount),0)::bigint unallocated_amount
  from base b
  join payment_summary ps
    on ps.kuri_id=b.kuri_id
   and ps.person_id in (b.original_person_id,b.current_holder_person_id)
   and ps.status='APPROVED'
   and (
     b.reason<>'DEATH'
     or b.death_date_verified_at is null
     or ps.payment_date::date<=b.death_date
   )
  group by b.exit_id
),
expenses as (
  select
    b.exit_id,
    coalesce(
      sum(
        case
          when eo.status='UNPAID'
           and (
             (
               b.reason='DEATH'
               and b.death_date_verified_at is not null
               and coalesce(eo.occurrence_date,eo.created_at::date)<=b.death_date
             )
             or
             (
               b.reason<>'DEATH'
               and coalesce(eo.occurrence_date,eo.created_at::date)
                   <=coalesce(b.requested_at,b.exit_date::timestamp)::date
             )
           )
          then eo.amount
          else 0
        end
      ),
      0
    )::bigint amount
  from base b
  left join public.expense_obligations eo
    on eo.membership_id=b.membership_id
  group by b.exit_id
),
winners as (
  select
    b.exit_id,
    coalesce(bool_or(mw.id is not null),false) has_win,
    coalesce(
      sum(
        case
          when mw.id is not null
           and (
             b.reason<>'DEATH'
             or b.death_date_verified_at is null
             or mw.finalized_at::date<=b.death_date
           )
           and (po.id is null or po.status in ('PENDING','PROCESSING'))
          then k.gross_prize_amount
          else 0
        end
      ),
      0
    )::bigint pending_prize
  from base b
  left join public.monthly_winner_memberships mwm
    on mwm.membership_id=b.membership_id
  left join public.monthly_winners mw
    on mw.id=mwm.monthly_winner_id
   and (
     b.reason<>'DEATH'
     or b.death_date_verified_at is null
     or mw.finalized_at::date<=b.death_date
   )
  left join public.cycles c on c.id=mw.cycle_id
  left join public.kuris k on k.id=c.kuri_id
  left join public.payouts po on po.monthly_winner_id=mw.id
  group by b.exit_id
),
installment_balances as (
  select
    i.id,
    i.membership_id,
    i.amount_due,
    least(
      i.amount_due,
      coalesce(sum(pa.allocated_amount),0)
    )::bigint effective_paid
  from public.installments i
  left join payment_alloc pa on pa.installment_id=i.id
  group by i.id,i.membership_id,i.amount_due
),
installments as (
  select
    b.exit_id,
    coalesce(
      sum(greatest(ib.amount_due-ib.effective_paid,0)),
      0
    )::bigint outstanding_amount
  from base b
  join installment_balances ib
    on ib.membership_id=b.membership_id
  group by b.exit_id
)
select
  b.exit_id,
  b.membership_id,
  b.kuri_id,
  b.original_person_id,
  b.current_holder_person_id,
  b.membership_number,
  b.reason,
  coalesce(b.requested_at,b.exit_date::timestamp),
  case
    when b.reason='DEATH' and b.death_date_verified_at is not null
    then b.death_date
    else null
  end,
  coalesce(c.allocated_amount,0),
  coalesce(au.unallocated_amount,0),
  case
    when w.has_win then coalesce(ins.outstanding_amount,0)
    else 0
  end,
  coalesce(e.amount,0),
  0::bigint,
  coalesce(w.pending_prize,0),
  coalesce(w.has_win,false),
  greatest(
    case
      when coalesce(w.has_win,false)
      then
        coalesce(w.pending_prize,0)
        +coalesce(au.unallocated_amount,0)
        -coalesce(ins.outstanding_amount,0)
        -coalesce(e.amount,0)
      else
        coalesce(c.allocated_amount,0)
        +coalesce(au.unallocated_amount,0)
        -coalesce(e.amount,0)
    end,
    0
  )
from base b
left join contrib c on c.exit_id=b.exit_id
left join all_unallocated au on au.exit_id=b.exit_id
left join expenses e on e.exit_id=b.exit_id
left join winners w on w.exit_id=b.exit_id
left join installments ins on ins.exit_id=b.exit_id;
$function$;

revoke all on function public.calculate_membership_exit_financials(uuid) from public;
grant execute on function public.calculate_membership_exit_financials(uuid) to authenticated;
