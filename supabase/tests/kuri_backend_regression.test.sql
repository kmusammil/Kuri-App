
-- Kuri-App database regression suite (pgTAP)
-- Run against a fresh local Supabase database after all migrations.
-- Tests are isolated by pgTAP transaction semantics.

begin;

select plan(83);

-- 1-4: core schema and RLS invariants
select ok(
  exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='kuris' and c.relrowsecurity
  ),
  'kuris has RLS enabled'
);

select ok(
  (select count(*) from pg_class c
   join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='r' and c.relrowsecurity)
  =
  (select count(*) from pg_class c
   join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='r'),
  'all public tables have RLS enabled'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid='public.payouts'::regclass
      and conname='payouts_net_amount_invariant'
  ),
  'payout net amount invariant exists'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid='public.muppu_records'::regclass
      and conname='muppu_records_kuri_cycle_person_key'
  ),
  'muppu uniqueness invariant exists'
);

-- 5-10: explicit organization/Kuri authority foundation
select ok(
  exists (
    select 1 from pg_type t
    join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public'
      and t.typname='organization_type'
      and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='PERSONAL')
      and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='ORGANIZATION')
  ),
  'organization type vocabulary exists'
);

select ok(
  exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='org_type')
  and exists (select 1 from information_schema.columns where table_schema='public' and table_name='organizations' and column_name='created_by')
  and exists (select 1 from information_schema.columns where table_schema='public' and table_name='kuris' and column_name='created_by'),
  'organization and Kuri creator metadata exists'
);

select ok(
  exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='kuri_admins' and c.relrowsecurity
  ),
  'kuri_admins exists with RLS'
);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.kuri_admins_one_main_admin_key'::regclass
      and indisunique
  ),
  'one Main Admin per Kuri is structurally constrained'
);

select ok(
  has_function_privilege('authenticated','public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,refund_policy)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,refund_policy)'::regprocedure,'EXECUTE'),
  'explicit organization-scoped Kuri creation is authenticated-only'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='list_my_organizations'
      and has_function_privilege('authenticated',p.oid,'EXECUTE')
      and not has_function_privilege('anon',p.oid,'EXECUTE')
  ),
  'explicit organization listing API is authenticated-only'
);

-- 5-8: domain identity immutability triggers exist on critical tenant keys
select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid='public.kuris'::regclass
      and tgfoid = 'public.enforce_domain_identity_immutability()'::regprocedure
  ),
  'kuri tenant identity immutability trigger exists'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid='public.people'::regclass
      and tgname like '%domain%identity%'
  ),
  'people tenant identity immutability trigger exists'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid='public.payments'::regclass
      and tgname like '%domain%identity%'
  ),
  'payment tenant identity immutability trigger exists'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid='public.memberships'::regclass
      and tgname like '%domain%identity%'
  ),
  'membership identity immutability trigger exists'
);

-- 9-12: invitation/join-request structural invariants

-- Kuri-level authority reconciliation
select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'list_kuris_for_admin',
        'get_kuri_for_admin',
        'list_memberships_for_admin',
        'list_people_available_for_membership',
        'create_membership_for_admin',
        'list_cycles_for_admin',
        'get_cycle_for_admin'
      )
      and pg_get_functiondef(p.oid) ilike '%has_kuri_admin_role%'
  ),
  7::bigint,
  'core Kuri reads and membership creation use Kuri-scoped authority'
);

select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'list_kuris_for_admin',
        'get_kuri_for_admin',
        'list_memberships_for_admin',
        'list_people_available_for_membership',
        'create_membership_for_admin',
        'list_cycles_for_admin',
        'get_cycle_for_admin'
      )
      and pg_get_functiondef(p.oid) ilike '%organization_users%'
  ),
  0::bigint,
  'core Kuri RPCs do not authorize through organization_users directly'
);

-- Remaining Kuri-scoped administrative surfaces
select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'generate_cycles_for_admin','generate_kuri_schedule_for_admin',
        'transition_kuri_status_for_admin','transition_cycle_status_for_admin',
        'transition_draw_status_for_admin','prepare_draw_for_admin',
        'set_draw_pool_entry_for_admin','run_random_draw_for_admin',
        'finalize_draw_for_admin','get_draw_session_for_admin',
        'get_draw_selections_for_admin','list_draw_pool_for_admin',
        'get_monthly_winners_for_admin','prepare_payout_for_admin',
        'get_payout_for_admin','list_payouts_for_admin',
        'mark_payout_paid_for_admin','transition_payout_status_for_admin',
        'create_membership_exit_for_admin','approve_membership_exit_for_admin',
        'settle_membership_exit_for_admin','transition_membership_exit_status_for_admin',
        'record_membership_exit_refund_for_admin','record_death_settlement_for_admin',
        'get_membership_exit_reconciliation_for_admin','get_death_settlement_context_for_admin',
        'list_membership_exits_for_admin','refresh_membership_exit_financials_for_admin',
        'get_membership_exit_membership_id_for_admin','get_membership_nominees_for_admin',
        'transition_membership_status_for_admin','create_muppu_record_for_admin',
        'list_muppu_records_for_admin','mark_muppu_paid_for_admin',
        'waive_muppu_for_admin','deduct_muppu_from_prize_for_admin'
      )
      and pg_get_functiondef(p.oid) ilike '%has_kuri_admin_role%'
  ),
  36::bigint,
  'remaining Kuri-scoped admin RPCs use Kuri-scoped authority'
);

select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'generate_cycles_for_admin','generate_kuri_schedule_for_admin',
        'transition_kuri_status_for_admin','transition_cycle_status_for_admin',
        'transition_draw_status_for_admin','prepare_draw_for_admin',
        'set_draw_pool_entry_for_admin','run_random_draw_for_admin',
        'finalize_draw_for_admin','get_draw_session_for_admin',
        'get_draw_selections_for_admin','list_draw_pool_for_admin',
        'get_monthly_winners_for_admin','prepare_payout_for_admin',
        'get_payout_for_admin','list_payouts_for_admin',
        'mark_payout_paid_for_admin','transition_payout_status_for_admin',
        'create_membership_exit_for_admin','approve_membership_exit_for_admin',
        'settle_membership_exit_for_admin','transition_membership_exit_status_for_admin',
        'record_membership_exit_refund_for_admin','record_death_settlement_for_admin',
        'get_membership_exit_reconciliation_for_admin','get_death_settlement_context_for_admin',
        'list_membership_exits_for_admin','refresh_membership_exit_financials_for_admin',
        'get_membership_exit_membership_id_for_admin','get_membership_nominees_for_admin',
        'transition_membership_status_for_admin','create_muppu_record_for_admin',
        'list_muppu_records_for_admin','mark_muppu_paid_for_admin',
        'waive_muppu_for_admin','deduct_muppu_from_prize_for_admin'
      )
      and pg_get_functiondef(p.oid) ilike '%organization_users%'
  ),
  0::bigint,
  'remaining Kuri-scoped admin RPCs do not authorize through organization_users directly'
);
select ok(
  exists (
    select 1 from pg_class c
    where c.oid='public.kuri_invitations'::regclass
      and c.relrowsecurity
  )
  and exists (
    select 1 from pg_class c
    where c.oid='public.kuri_join_requests'::regclass
      and c.relrowsecurity
  ),
  'invitation and join-request tables have RLS'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.kuri_invitations'::regclass
      and conname='kuri_invitations_code_hash_key'
  ),
  'invitation code hashes are unique'
);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.kuri_join_requests_one_pending_key'::regclass
      and indisunique
  ),
  'only one pending join request per applicant and Kuri is enforced'
);

select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname in (
       'create_kuri_invitation_for_admin',
       'revoke_kuri_invitation_for_admin',
       'accept_kuri_invitation',
       'list_kuri_join_requests_for_admin',
       'list_kuri_invitations_for_admin',
       'approve_kuri_join_request_for_admin',
       'reject_kuri_join_request_for_admin'
     )
     and p.prosecdef
     and has_function_privilege('authenticated',p.oid,'EXECUTE')
     and has_function_privilege('anon',p.oid,'EXECUTE')
  ),
  0::bigint,
  'invitation/join-request SECURITY DEFINER APIs are not anonymous-callable'
);

-- 9-14: state machine transition matrices using isolated temp tables
create temp table t_kuri(id int primary key, status public.kuri_status);
create trigger t_kuri_guard before update of status on t_kuri
for each row execute function public.enforce_kuri_status_transition();

insert into t_kuri values (1,'DRAFT');
select is(
  (select status from t_kuri where id=1),
  'DRAFT'::public.kuri_status,
  'kuri starts in DRAFT'
);

update t_kuri set status='OPEN' where id=1;
select is((select status from t_kuri where id=1),'OPEN'::public.kuri_status,'DRAFT -> OPEN allowed');

select throws_ok(
  $$update t_kuri set status='COMPLETED' where id=1$$,
  NULL,
  NULL,
  'invalid Kuri transition OPEN -> COMPLETED rejected'
);

create temp table t_cycle(id int primary key, status public.cycle_status);
create trigger t_cycle_guard before update of status on t_cycle
for each row execute function public.enforce_cycle_status_transition();
insert into t_cycle values(1,'PAYMENT_CLOSED');
select lives_ok(
  $$update t_cycle set status='DRAW_PENDING' where id=1$$,
  'cycle PAYMENT_CLOSED -> DRAW_PENDING allowed'
);

select throws_ok(
  $$update t_cycle set status='UPCOMING' where id=1$$,
  NULL,
  NULL,
  'invalid cycle transition DRAW_PENDING -> UPCOMING rejected'
);

create temp table t_draw(id int primary key, status public.draw_status);
create trigger t_draw_guard before update of status on t_draw
for each row execute function public.enforce_draw_status_transition();
insert into t_draw values(1,'POOL_READY');
select lives_ok(
  $$update t_draw set status='DRAWING' where id=1$$,
  'draw POOL_READY -> DRAWING allowed'
);

select throws_ok(
  $$update t_draw set status='FINALIZED' where id=1$$,
  NULL,
  NULL,
  'invalid draw transition DRAWING -> FINALIZED rejected'
);

create temp table t_payout(id int primary key, status public.payout_status);
create trigger t_payout_guard before update of status on t_payout
for each row execute function public.enforce_payout_status_transition();
insert into t_payout values(1,'PENDING');
select lives_ok(
  $$update t_payout set status='PROCESSING' where id=1$$,
  'payout PENDING -> PROCESSING allowed'
);

select throws_ok(
  $$update t_payout set status='PAID' where id=1$$,
  NULL,
  NULL,
  'invalid payout transition PENDING -> PAID rejected'
);

create temp table t_membership(id int primary key, status public.membership_status);
create trigger t_membership_guard before update of status on t_membership
for each row execute function public.enforce_membership_status_transition();
insert into t_membership values(1,'ACTIVE');
select lives_ok(
  $$update t_membership set status='SUSPENDED' where id=1$$,
  'membership ACTIVE -> SUSPENDED allowed'
);

create temp table t_exit(id int primary key, status public.settlement_status);
create trigger t_exit_guard before update of status on t_exit
for each row execute function public.enforce_membership_exit_status_transition();
insert into t_exit values(1,'PENDING');
select lives_ok(
  $$update t_exit set status='APPROVED' where id=1$$,
  'membership exit PENDING -> APPROVED allowed'
);

-- 15-18: uniqueness constraints
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.payouts'::regclass
      and conname='payouts_monthly_winner_id_key'
  ),
  'one payout per monthly winner constraint exists'
);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.monthly_winners_cycle_person_key'::regclass
      and indisunique
  ),
  'one winner per person per cycle uniqueness exists'
);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.draw_selections_draw_membership_key'::regclass
      and indisunique
  ),
  'one membership selection per draw uniqueness exists'
);

select ok(
  exists (
    select 1 from pg_index
    where indexrelid='public.draw_selections_draw_order_key'::regclass
      and indisunique
  ),
  'selection order uniqueness per draw exists'
);

-- 19-22: rule vocabulary and cross-domain immutability enforcement
select ok(
  (select count(*) from pg_constraint
   where conrelid='public.kuris'::regclass
     and conname like '%draw%eligibility%') >= 1,
  'draw eligibility rule integrity constraint exists'
);

select ok(
  (select count(*) from pg_constraint
   where conrelid='public.kuris'::regclass
     and conname like '%winner%rule%') >= 1,
  'winner rule integrity constraint exists'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid='public.cycles'::regclass and tgname like '%domain%identity%'
  ),
  'cycle Kuri identity immutability trigger exists'
);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid='public.installments'::regclass and tgname like '%domain%identity%'
  ),
  'installment membership/cycle identity immutability trigger exists'
);

-- 23-26: financial schema invariants
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.payouts'::regclass
      and conname='payouts_paid_details_invariant'
  ),
  'paid payout payment-details invariant exists'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.payments'::regclass
      and conname='payments_organization_id_fkey'
  ),
  'payment organization foreign key exists'
);

select ok(
  exists (
    select 1 from pg_index
    where indrelid='public.payments'::regclass
      and indexrelid='public.payments_organization_id_idx'::regclass
  ),
  'payment organization index exists'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='audit_financial_change'
      and p.prosecdef
  ),
  'financial audit trigger function is SECURITY DEFINER'
);

-- 27-30: security exposure invariants
select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.prosecdef
      and has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  0::bigint,
  'anon cannot execute public SECURITY DEFINER functions'
);

select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.prosecdef
      and (p.proconfig is null or not exists (
        select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%'
      ))
  ),
  0::bigint,
  'all public SECURITY DEFINER functions have an explicit search_path'
);

select ok(
  not has_table_privilege('anon','public.payments','INSERT'),
  'anon cannot insert payments directly'
);

select ok(
  not has_table_privilege('authenticated','public.draw_pool_entries','INSERT'),
  'authenticated cannot insert draw-pool rows directly'
);

-- 31-34: live data integrity checks
select is(
  (select count(*) from public.monthly_winners mw
   join public.cycles c on c.id=mw.cycle_id
   join public.kuris k on k.id=c.kuri_id
   join public.people p on p.id=mw.person_id
   where p.organization_id is distinct from k.organization_id),
  0::bigint,
  'all existing winners respect organization tenancy'
);

select is(
  (select count(*) from public.installments i
   join public.memberships m on m.id=i.membership_id
   join public.cycles c on c.id=i.cycle_id
   where m.kuri_id is distinct from c.kuri_id),
  0::bigint,
  'all existing installments match membership and cycle Kuri'
);

select is(
  (select count(*) from public.payment_allocations pa
   join public.payments p on p.id=pa.payment_id
   join public.installments i on i.id=pa.installment_id
   join public.memberships m on m.id=i.membership_id
   where p.person_id is distinct from m.person_id
      or p.organization_id is distinct from (select k.organization_id from public.kuris k where k.id=m.kuri_id)),
  0::bigint,
  'all existing payment allocations preserve person and organization identity'
);

select is(
  (select count(*) from public.payouts po
   join public.monthly_winners mw on mw.id=po.monthly_winner_id
   join public.cycles c on c.id=mw.cycle_id
   where c.status <> 'COMPLETED'
     and po.created_at >= timestamp '2026-09-20 00:00:00+00'),
  0::bigint,
  'new payouts are linked only to completed cycles'
);


-- 49-54: payment Kuri scoping and legacy authority invariants
select ok(
  exists (
    select 1
    from information_schema.columns
    where table_schema='public'
      and table_name='payments'
      and column_name='kuri_id'
      and is_nullable='NO'
  ),
  'payments have a required Kuri tenant key'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid='public.payments'::regclass
      and conname='payments_kuri_organization_fkey'
  ),
  'payments enforce Kuri and organization consistency'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text)'::regprocedure,
    'EXECUTE'
  )
  and to_regprocedure('public.create_payment_for_admin(uuid,bigint,timestamptz,public.payment_method,text,text)') is null,
  'payment creation API uses the new Kuri-scoped signature only'
);

select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'create_payment_for_admin',
        'list_payments_for_admin',
        'get_payment_for_admin',
        'list_installments_for_person_payment_admin',
        'list_installments_for_payment_admin',
        'list_installments_for_cycle_admin',
        'list_payment_allocations_for_admin',
        'allocate_payment_for_admin',
        'audit_financial_ledger_for_admin',
        'refresh_membership_exit_financials_for_admin'
      )
      and pg_get_functiondef(p.oid) ilike '%has_kuri_admin_role%'
  ),
  10::bigint,
  'all payment/installation admin APIs use Kuri-scoped authority'
);

select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in (
        'create_payment_for_admin',
        'list_payments_for_admin',
        'get_payment_for_admin',
        'list_installments_for_person_payment_admin',
        'list_installments_for_payment_admin',
        'list_installments_for_cycle_admin',
        'list_payment_allocations_for_admin',
        'allocate_payment_for_admin',
        'audit_financial_ledger_for_admin',
        'refresh_membership_exit_financials_for_admin'
      )
      and pg_get_functiondef(p.oid) ilike '%organization_users%'
  ),
  0::bigint,
  'payment/installation admin APIs do not authorize through organization_users directly'
);

select is(
  (
    select count(*)
    from public.kuris k
    where not exists (
      select 1
      from public.kuri_admins ka
      where ka.kuri_id=k.id
        and ka.role='MAIN_ADMIN'
    )
  ),
  0::bigint,
  'every existing Kuri has a recovered Main Admin authority row'
);


-- 60-65: payment operation idempotency invariants
select ok(
  exists (
    select 1 from pg_class
    where oid='public.financial_idempotency_keys'::regclass
      and relrowsecurity
  ),
  'financial idempotency key ledger has RLS'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.financial_idempotency_keys'::regclass
      and conname='financial_idempotency_keys_actor_user_id_operation_type_idempotency_key_key'
  ),
  'payment operation idempotency key is unique per actor and operation'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text)'::regprocedure,
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'public.allocate_payment_for_admin(uuid,uuid,bigint,text)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text)'::regprocedure,
    'EXECUTE'
  ),
  'idempotent payment mutation APIs are authenticated-only'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='create_payment_for_admin'
      and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'
      and pg_get_functiondef(p.oid) ilike '%request_hash%'
  )
  and exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='allocate_payment_for_admin'
      and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'
      and pg_get_functiondef(p.oid) ilike '%request_hash%'
  ),
  'payment create and allocation functions bind retries to request hashes'
);

select is(
  (
    select count(*)
    from public.financial_idempotency_keys f
  ),
  0::bigint,
  'no idempotency keys persisted by rollback-only verification'
);

select ok(
  not has_table_privilege('anon','public.financial_idempotency_keys','SELECT')
  and not has_table_privilege('authenticated','public.financial_idempotency_keys','SELECT'),
  'clients cannot directly read financial idempotency keys'
);



-- 66-75: payment correction/reversal structural contract
select ok(
  exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
          where n.nspname='public' and t.typname='payment_adjustment_type'
            and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='CORRECTION')
            and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='REVERSAL'))
  and exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
          where n.nspname='public' and t.typname='payment_adjustment_status'
            and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='REQUESTED')
            and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='APPROVED')
            and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='EXECUTED')
            and exists (select 1 from pg_enum e where e.enumtypid=t.oid and e.enumlabel='REJECTED')),
  'payment adjustment type and status vocabularies exist'
);
select ok(
  (select count(*) from pg_class where oid in ('public.payment_adjustment_requests'::regclass,'public.payment_corrections'::regclass,'public.payment_reversal_entries'::regclass) and relrowsecurity)=3,
  'payment adjustment ledgers have RLS enabled'
);
select ok(
  not has_table_privilege('anon','public.payment_adjustment_requests','SELECT')
  and not has_table_privilege('authenticated','public.payment_adjustment_requests','SELECT')
  and not has_table_privilege('anon','public.payment_corrections','SELECT')
  and not has_table_privilege('authenticated','public.payment_corrections','SELECT')
  and not has_table_privilege('anon','public.payment_reversal_entries','SELECT')
  and not has_table_privilege('authenticated','public.payment_reversal_entries','SELECT'),
  'clients cannot directly read payment adjustment ledgers'
);
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef
     and has_function_privilege('authenticated',p.oid,'EXECUTE')
     and p.proname in ('create_payment_correction_request_for_admin','create_payment_reversal_request_for_admin','approve_payment_adjustment_request_for_admin','reject_payment_adjustment_request_for_admin','execute_payment_adjustment_request_for_admin','list_payment_adjustment_requests_for_admin','get_payment_adjustment_request_for_admin')),7::bigint,
  'seven payment correction/reversal APIs are exposed to authenticated clients'
);
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef
     and has_function_privilege('anon',p.oid,'EXECUTE')
     and p.proname in ('create_payment_correction_request_for_admin','create_payment_reversal_request_for_admin','approve_payment_adjustment_request_for_admin','reject_payment_adjustment_request_for_admin','execute_payment_adjustment_request_for_admin','list_payment_adjustment_requests_for_admin','get_payment_adjustment_request_for_admin')),0::bigint,
  'payment correction/reversal APIs are not anonymous-callable'
);
select ok(
  not has_function_privilege('anon','public.get_effective_payment_amount(uuid)'::regprocedure,'EXECUTE')
  and not has_function_privilege('authenticated','public.get_effective_payment_amount(uuid)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.get_effective_payment_allocation_amount(uuid)'::regprocedure,'EXECUTE')
  and not has_function_privilege('authenticated','public.get_effective_payment_allocation_amount(uuid)'::regprocedure,'EXECUTE')
  and not has_function_privilege('authenticated','public.reconcile_installment_from_allocations(uuid)'::regprocedure,'EXECUTE'),
  'effective financial helpers remain internal'
);
select ok(
  exists (select 1 from pg_constraint where conrelid='public.payment_adjustment_requests'::regclass and pg_get_constraintdef(oid) ilike '%reason%')
  and exists (select 1 from pg_constraint where conrelid='public.payment_adjustment_requests'::regclass and pg_get_constraintdef(oid) ilike '%REJECTED%')
  and exists (select 1 from pg_constraint where conrelid='public.payment_reversal_entries'::regclass and conname='payment_reversal_entries_kuri_org_fkey'),
  'adjustment reason/status and Kuri tenancy constraints exist'
);
select ok(
  exists (select 1 from pg_constraint where conrelid='public.payment_corrections'::regclass and conname='payment_corrections_kuri_org_fkey')
  and exists (select 1 from pg_index where indexrelid='public.payment_reversal_entries_one_unallocated_per_request'::regclass and indisunique),
  'append-only correction/reversal structural invariants exist'
);
select ok(
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='get_payment_for_admin' and pg_get_functiondef(p.oid) ilike '%get_effective_payment_amount%')
  and exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='list_payment_allocations_for_admin' and pg_get_functiondef(p.oid) ilike '%get_effective_payment_allocation_amount%'),
  'payment read APIs expose effective financial values'
);
select ok(
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='reject_payment_adjustment_request_for_admin'
            and pg_get_functiondef(p.oid) ilike '%p_rejection_reason%')
  and not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='reject_payment_adjustment_request_for_admin'
            and pg_get_functiondef(p.oid) ilike '%btrim(rejection_reason)%'),
  'payment rejection API uses unambiguous input parameter naming'
);


-- 76-83: payment allocation policy
select ok(
  to_regprocedure('public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)') is not null
  and has_function_privilege('authenticated','public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)'::regprocedure,'EXECUTE'),
  'oldest-first advance allocation API is authenticated-only'
);
select ok(
  to_regprocedure('public.allocate_payment_to_oldest_installments_for_admin(uuid,bigint,text)') is null,
  'stale ambiguous advance allocation signature is removed'
);
select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='allocate_payment_for_admin'
      and pg_get_functiondef(p.oid) ilike '%Cannot skip outstanding earlier installments%'
  ),
  'targeted allocation rejects skipping earlier outstanding installments'
);
select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='allocate_payment_for_admin'
      and pg_get_functiondef(p.oid) ilike '%ORDER BY lock_c.cycle_number,lock_i.id%'
      and pg_get_functiondef(p.oid) ilike '%FOR UPDATE%'
  ),
  'targeted allocation locks installments in deterministic cycle order'
);
select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%target_membership_id%'
      and pg_get_functiondef(p.oid) ilike '%Payment person does not match membership person%'
  ),
  'advance allocation is explicitly membership-scoped'
);
select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%ORDER BY oc.cycle_number,oi.id%'
      and pg_get_functiondef(p.oid) ilike '%requested_allocation_amount>total_outstanding%'
  ),
  'advance allocation is oldest-first and bounded by membership outstanding balance'
);
select ok(
  exists (
    select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='allocate_payment_to_oldest_installments_for_admin'
      and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'
      and pg_get_functiondef(p.oid) ilike '%PAYMENT_ALLOCATION%'
  ),
  'advance allocation uses the existing financial idempotency ledger'
);
select ok(
  has_function_privilege('authenticated','public.allocate_payment_for_admin(uuid,uuid,bigint,text)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.allocate_payment_for_admin(uuid,uuid,bigint,text)'::regprocedure,'EXECUTE'),
  'targeted allocation API remains authenticated-only after policy hardening'
);

select * from finish();

rollback;
