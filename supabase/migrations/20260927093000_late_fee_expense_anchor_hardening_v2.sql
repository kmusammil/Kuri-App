begin;

-- LATE-FEE-001 hardening:
-- Late fees are per-installment financial obligations. Their system Expense
-- anchor therefore uses the existing RECURRING/PER_CYCLE Expense semantics,
-- not ONE_TIME semantics, so each installment can carry cycle/date identity.
update public.expense_rules
set frequency='RECURRING'::public.expense_frequency,
    recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern,
    recurrence_interval=null,
    recurrence_start_date=null,
    recurrence_end_date=null,
    active=false,
    updated_at=now()
where name='[SYSTEM] Late Fee Charges'
  and description='System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.';

create or replace function public.ensure_kuri_late_fee_support(target_kuri_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_expense_rule_id uuid;
begin
  if target_kuri_id is null then
    raise exception 'Kuri is required.';
  end if;

  select er.id
    into v_expense_rule_id
  from public.expense_rules er
  where er.kuri_id=target_kuri_id
    and er.name='[SYSTEM] Late Fee Charges'
    and er.description='System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.'
  order by er.created_at
  limit 1;

  if v_expense_rule_id is null then
    insert into public.expense_rules(
      kuri_id,name,description,frequency,amount,active,
      recurrence_pattern,recurrence_interval,recurrence_start_date,recurrence_end_date,created_by
    )
    select
      k.id,
      '[SYSTEM] Late Fee Charges',
      'System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.',
      'RECURRING'::public.expense_frequency,
      1,
      false,
      'PER_CYCLE'::public.expense_recurrence_pattern,
      null,
      null,
      null,
      null
    from public.kuris k
    where k.id=target_kuri_id
    returning id into v_expense_rule_id;
  else
    update public.expense_rules
    set frequency='RECURRING'::public.expense_frequency,
        recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern,
        recurrence_interval=null,
        recurrence_start_date=null,
        recurrence_end_date=null,
        active=false,
        updated_at=now()
    where id=v_expense_rule_id;
  end if;

  if v_expense_rule_id is null then
    raise exception 'Kuri not found.';
  end if;

  insert into public.kuri_late_fee_rules(
    kuri_id,expense_rule_id,enabled,fee_type,fixed_amount,percentage_basis_points,
    grace_period_days,effective_from
  )
  select
    target_kuri_id,v_expense_rule_id,false,'FIXED',null,null,0,current_date
  where not exists (
    select 1
    from public.kuri_late_fee_rules r
    where r.kuri_id=target_kuri_id and r.effective_to is null
  );
end;
$$;

revoke all on function public.ensure_kuri_late_fee_support(uuid) from public, anon, authenticated;

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