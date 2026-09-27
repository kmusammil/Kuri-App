-- PAYMENT-002: post-finalization payment correction/reversal approval workflow
begin;

select plan(14);

select ok(
  exists (
    select 1 from pg_type t
    where t.typnamespace='public'::regnamespace
      and t.typname='payment_adjustment_status'
  ),
  'payment adjustment status type exists'
);

select ok(
  (
    select array_agg(e.enumlabel order by e.enumsortorder)
    from pg_type t
    join pg_enum e on e.enumtypid=t.oid
    where t.typnamespace='public'::regnamespace
      and t.typname='payment_adjustment_status'
  ) = array['REQUESTED','APPROVED','EXECUTED','REJECTED']::text[],
  'approval workflow has REQUESTED, APPROVED, EXECUTED, REJECTED states'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='create_payment_correction_request_for_admin'
  ),
  'correction request API exists'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='create_payment_reversal_request_for_admin'
  ),
  'reversal request API exists'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='approve_payment_adjustment_request_for_admin'
  ),
  'approval API exists'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='reject_payment_adjustment_request_for_admin'
  ),
  'rejection API exists'
);

select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='execute_payment_adjustment_request_for_admin'
  ),
  'execution API exists'
);

select ok(
  pg_get_functiondef('public.approve_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%status=''REQUESTED''%'
    and pg_get_functiondef('public.approve_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%status=''APPROVED''%',
  'approval only advances REQUESTED to APPROVED'
);

select ok(
  pg_get_functiondef('public.reject_payment_adjustment_request_for_admin(uuid,text)'::regprocedure)
    ilike '%status=''REQUESTED''%'
    and pg_get_functiondef('public.reject_payment_adjustment_request_for_admin(uuid,text)'::regprocedure)
    ilike '%status=''REJECTED''%',
  'rejection only advances REQUESTED to REJECTED'
);

select ok(
  pg_get_functiondef('public.execute_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%status<>''APPROVED''%'
    and pg_get_functiondef('public.execute_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%status=''EXECUTED''%',
  'execution requires APPROVED and ends in EXECUTED'
);

select ok(
  pg_get_functiondef('public.approve_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%has_kuri_admin_role%'
    and pg_get_functiondef('public.reject_payment_adjustment_request_for_admin(uuid,text)'::regprocedure)
    ilike '%has_kuri_admin_role%'
    and pg_get_functiondef('public.execute_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%has_kuri_admin_role%',
  'all review/execute actions enforce Kuri admin authority'
);

select ok(
  has_function_privilege('anon','public.approve_payment_adjustment_request_for_admin(uuid)','EXECUTE') = false
  and has_function_privilege('anon','public.reject_payment_adjustment_request_for_admin(uuid,text)','EXECUTE') = false
  and has_function_privilege('anon','public.execute_payment_adjustment_request_for_admin(uuid)','EXECUTE') = false,
  'review and execution APIs are not executable by anon'
);

select ok(
  pg_get_functiondef('public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text,text)'::regprocedure)
    ilike '%''REQUESTED''%'
  and pg_get_functiondef('public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text,text)'::regprocedure)
    ilike '%''REQUESTED''%',
  'new correction/reversal requests start in REQUESTED'
);

select ok(
  pg_get_functiondef('public.execute_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%insert into public.payment_corrections%'
    and pg_get_functiondef('public.execute_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%insert into public.payment_reversal_entries%',
  'execution writes append-only correction/reversal ledger entries'
);

select ok(
  pg_get_functiondef('public.approve_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%audit_logs%'
    and pg_get_functiondef('public.reject_payment_adjustment_request_for_admin(uuid,text)'::regprocedure)
    ilike '%audit_logs%'
    and pg_get_functiondef('public.execute_payment_adjustment_request_for_admin(uuid)'::regprocedure)
    ilike '%audit_logs%',
  'request review and execution are audited'
);

select * from finish();
rollback;
