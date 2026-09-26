-- PAYMENT-005: advance-payment handling for future installments
-- Read-only pgTAP contract checks; no fixture rows are created or mutated.

begin;

select plan(8);

select ok(
  to_regprocedure('public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)') is not null,
  'advance-payment allocation API exists'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)'::regprocedure,
    'EXECUTE'
  ),
  'advance-payment allocation is authenticated-only'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%ORDER BY oc.cycle_number,oi.id%'
  ),
  'advance payments are allocated in cycle order'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%requested_allocation_amount>total_outstanding%'
      and pg_get_functiondef(p.oid) ilike '%Allocation exceeds the total outstanding installments for this membership%'
  ),
  'advance payments cannot exceed total outstanding installments'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%available_payment%'
      and pg_get_functiondef(p.oid) ilike '%requested_allocation_amount>available_payment%'
  ),
  'advance payments cannot exceed the payment balance available for allocation'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%payment_allocations%'
      and pg_get_functiondef(p.oid) ilike '%reconcile_installment_from_allocations%'
  ),
  'advance allocation records each installment allocation and reconciles it'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'
      and pg_get_functiondef(p.oid) ilike '%PAYMENT_ALLOCATION%'
  ),
  'advance-payment retries use the financial idempotency ledger'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%payment_person_id<>membership_person_id%'
      and pg_get_functiondef(p.oid) ilike '%Payment person does not match the original member or current holder%'
  ),
  'advance payments remain restricted to the membership holder identity'
);

select * from finish();

rollback;
