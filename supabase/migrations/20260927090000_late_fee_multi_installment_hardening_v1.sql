begin;

-- LATE-FEE-001 hardening:
-- preserve the installment identity through the Expense insertion so that
-- multiple late fees generated for one membership cannot cross-link.
create or replace function public.generate_late_fee_obligations_for_membership_internal(
  target_membership_id uuid,
  through_date date
)
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_created integer:=0;
begin
  if target_membership_id is null or through_date is null then
    raise exception 'Membership and through date are required.';
  end if;

  if through_date>current_date then
    raise exception 'Late-fee obligations cannot be generated for a future date.';
  end if;

  with candidates as (
    select
      i.id installment_id,
      i.membership_id,
      i.cycle_id,
      i.amount_due,
      i.due_date,
      r.id late_fee_rule_id,
      r.expense_rule_id,
      (i.due_date + r.grace_period_days) fee_due_date,
      case
        when r.fee_type='FIXED' then r.fixed_amount
        else greatest(
          1::numeric,
          round(i.amount_due::numeric * r.percentage_basis_points::numeric / 10000.0)
        )::bigint
      end fee_amount,
      coalesce(paid.paid_by_deadline,0)::bigint paid_by_deadline
    from public.installments i
    join public.memberships m on m.id=i.membership_id
    join lateral (
      select r.*
      from public.kuri_late_fee_rules r
      where r.kuri_id=m.kuri_id
        and r.enabled
        and i.due_date>=r.effective_from
        and (r.effective_to is null or i.due_date<=r.effective_to)
      order by r.effective_from desc,r.created_at desc
      limit 1
    ) r on true
    left join lateral (
      select coalesce(sum(
        public.get_effective_payment_allocation_amount(pa.id)
      ),0)::bigint paid_by_deadline
      from public.payment_allocations pa
      join public.payments p on p.id=pa.payment_id
      where pa.installment_id=i.id
        and p.status='APPROVED'
        and p.payment_date::date <= (i.due_date + r.grace_period_days)
    ) paid on true
    where i.membership_id=target_membership_id
      and i.status<>'WAIVED'
      and through_date >= (i.due_date + r.grace_period_days)
      and coalesce(paid.paid_by_deadline,0) < i.amount_due
      and not exists (
        select 1
        from public.membership_exits me
        where me.membership_id=i.membership_id
          and me.status in ('PENDING','APPROVED','SETTLED')
          and (i.due_date + r.grace_period_days) >
              coalesce(
                case
                  when me.reason='DEATH' and me.death_date_verified_at is not null
                  then me.death_date
                  else me.requested_at::date
                end,
                me.exit_date
              )
      )
      and not exists (
        select 1
        from public.late_fee_obligations lfo
        where lfo.installment_id=i.id
      )
  ), inserted as (
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,
      status,occurrence_date,settlement_reference
    )
    select
      c.expense_rule_id,
      m.kuri_id,
      c.membership_id,
      c.cycle_id,
      c.fee_amount,
      'UNPAID'::public.expense_obligation_status,
      c.fee_due_date,
      'LATE_FEE:'||c.installment_id::text
    from candidates c
    join public.memberships m on m.id=c.membership_id
    where c.fee_amount>0
    on conflict do nothing
    returning id,membership_id,settlement_reference
  )
  insert into public.late_fee_obligations(
    kuri_id,membership_id,installment_id,late_fee_rule_id,
    expense_obligation_id,fee_due_date
  )
  select
    m.kuri_id,
    c.membership_id,
    c.installment_id,
    c.late_fee_rule_id,
    iob.id,
    c.fee_due_date
  from candidates c
  join inserted iob
    on iob.membership_id=c.membership_id
   and iob.settlement_reference='LATE_FEE:'||c.installment_id::text
  join public.memberships m on m.id=c.membership_id
  on conflict (installment_id) do nothing;

  get diagnostics v_created=row_count;
  return v_created;
end;
$function$;

revoke all on function public.generate_late_fee_obligations_for_membership_internal(uuid,date) from public, anon, authenticated;

commit;