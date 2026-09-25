
-- Kuri-App database regression suite (pgTAP)
-- Run against a fresh local Supabase database after all migrations.
-- Tests are isolated by pgTAP transaction semantics.

begin;

select plan(48);

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

select * from finish();

rollback;
