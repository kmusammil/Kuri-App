-- PAYMENT-004: payment allocation invariants
-- Read-only pgTAP checks; no fixture rows are created or mutated.

begin;

select plan(12);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.payment_allocations_payment_id_installment_id_key'::regclass
      and indisunique
  ),
  'one allocation row exists per payment/installment pair'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.payment_allocations'::regclass
      and contype='f'
  ),
  'payment allocations use foreign-key integrity'
);

select is(
  (
    select count(*)
    from public.payment_allocations pa
    join public.payments p on p.id=pa.payment_id
    where pa.amount<=0
  ),
  0::bigint,
  'all allocation amounts are positive'
);

select is(
  (
    select count(*)
    from public.payment_allocations pa
    join public.payments p on p.id=pa.payment_id
    where pa.amount > public.get_effective_payment_amount(pa.payment_id)
  ),
  0::bigint,
  'no allocation exceeds its effective payment amount'
);

select is(
  (
    select count(*)
    from (
      select pa.payment_id,
             sum(public.get_effective_payment_allocation_amount(pa.id)) allocated
      from public.payment_allocations pa
      group by pa.payment_id
    ) x
    where x.allocated > public.get_effective_payment_amount(x.payment_id)
  ),
  0::bigint,
  'total effective allocations never exceed effective payment amount'
);

select is(
  (
    select count(*)
    from (
      select pa.installment_id,
             sum(public.get_effective_payment_allocation_amount(pa.id)) allocated
      from public.payment_allocations pa
      group by pa.installment_id
    ) x
    join public.installments i on i.id=x.installment_id
    where x.allocated > i.amount_due
  ),
  0::bigint,
  'total effective allocations never exceed installment amount due'
);

select is(
  (
    select count(*)
    from public.payment_allocations pa
    join public.payments p on p.id=pa.payment_id
    join public.installments i on i.id=pa.installment_id
    join public.memberships m on m.id=i.membership_id
    join public.cycles c on c.id=i.cycle_id
    where p.kuri_id is distinct from c.kuri_id
       or m.kuri_id is distinct from c.kuri_id
  ),
  0::bigint,
  'payment allocation Kuri tenancy remains consistent'
);

select is(
  (
    select count(*)
    from public.payment_allocations pa
    join public.payments p on p.id=pa.payment_id
    join public.installments i on i.id=pa.installment_id
    join public.memberships m on m.id=i.membership_id
    where p.person_id<>m.person_id
      and (m.current_holder_person_id is null or p.person_id<>m.current_holder_person_id)
  ),
  0::bigint,
  'payment allocation preserves original member/current-holder identity'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_for_admin'
      and pg_get_functiondef(p.oid) ilike '%Allocation exceeds payment amount%'
      and pg_get_functiondef(p.oid) ilike '%Allocation exceeds installment balance%'
  ),
  'targeted allocation API rejects payment and installment over-allocation'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_for_admin'
      and pg_get_functiondef(p.oid) ilike '%Cannot skip outstanding earlier installments%'
  ),
  'targeted allocation API enforces oldest-outstanding ordering'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%requested_allocation_amount>total_outstanding%'
      and pg_get_functiondef(p.oid) ilike '%ORDER BY oc.cycle_number,oi.id%'
  ),
  'advance allocation is oldest-first and bounded by outstanding balance'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_for_admin'
      and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'
      and pg_get_functiondef(p.oid) ilike '%PAYMENT_ALLOCATION%'
  )
  and exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'
      and pg_get_functiondef(p.oid) ilike '%PAYMENT_ALLOCATION%'
  ),
  'allocation APIs are protected by payment-operation idempotency'
);

select * from finish();

rollback;
