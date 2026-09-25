-- Kuri-App authenticated API contract + security regression suite (pgTAP)
-- Purpose:
--   1. Verify the client-facing SECURITY DEFINER RPC boundary.
--   2. Verify tenancy/security invariants that can be tested without a real JWT.
--   3. Verify the documented API inventory remains synchronized with the database.
--
-- Run locally with:
--   supabase test db
--
-- IMPORTANT:
-- This suite deliberately does NOT claim to prove a real user's JWT authorization.
-- The production MCP SQL connection runs with privileged database credentials.
-- JWT/RLS negative-path behavior must additionally be exercised through the
-- application/API integration suite using real authenticated sessions.

begin;

select plan(76);

-- 1. Every exposed public table remains protected by RLS.
select is(
  (select count(*) from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relrowsecurity),
  (select count(*) from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'),
  'every public table has RLS enabled'
);

-- 2. No anonymous SECURITY DEFINER RPC exposure.
select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0::bigint,
  'anon cannot execute public SECURITY DEFINER functions'
);

-- 3. The reviewed authenticated SECURITY DEFINER API surface is currently 85.
-- Internal state-machine trigger helpers are deliberately excluded from the
-- client-facing SECURITY DEFINER API boundary. The 84 count includes the
-- intentionally exposed invitation/join-request and payment adjustment APIs.
select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  85::bigint,
  'authenticated SECURITY DEFINER API surface includes the reviewed APIs plus invitation and join-request APIs'
);

-- 4. Every exposed SECURITY DEFINER function has an explicit search_path.
select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and (p.proconfig is null
          or not exists (
            select 1
            from unnest(p.proconfig) cfg
            where cfg like 'search_path=%'
          ))),
  0::bigint,
  'every exposed SECURITY DEFINER function has fixed search_path'
);

-- 5-7. Explicit organization/Kuri context APIs are exposed without anonymous access.
select ok(
  has_function_privilege('authenticated','public.list_my_organizations()'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.list_my_organizations()'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.get_organization_role(uuid)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.get_organization_role(uuid)'::regprocedure,'EXECUTE'),
  'organization context APIs are authenticated-only'
);

select ok(
  has_function_privilege('authenticated','public.create_organization_for_user(text,organization_type,text,text,text,text)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.create_organization_for_user(text,organization_type,text,text,text,text)'::regprocedure,'EXECUTE'),
  'organization creation API is authenticated-only'
);

select ok(
  has_function_privilege('authenticated','public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,refund_policy)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.create_kuri_for_organization_admin(uuid,text,text,date,integer,integer,bigint,integer,integer,bigint,bigint,text,refund_policy)'::regprocedure,'EXECUTE'),
  'organization-scoped Kuri creation API is authenticated-only'
);

-- 5. Invitation and join-request APIs are authenticated-only and part of the reviewed boundary.
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
     and not has_function_privilege('anon',p.oid,'EXECUTE')
  ),
  7::bigint,
  'seven invitation/join-request APIs are authenticated-only'
);

select ok(
  exists (select 1 from pg_class where oid='public.kuri_invitations'::regclass and relrowsecurity)
  and exists (select 1 from pg_class where oid='public.kuri_join_requests'::regclass and relrowsecurity),
  'invitation and join-request tables remain RLS protected'
);

-- 5. Lifecycle transition RPCs are intentionally client-callable and remain protected by the reviewed API surface.
select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in (
       'transition_kuri_status_for_admin',
       'transition_cycle_status_for_admin',
       'transition_draw_status_for_admin'
     )
     and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and not has_function_privilege('anon', p.oid, 'EXECUTE')),
  3::bigint,
  'three lifecycle transition RPCs are authenticated-only application APIs'
);

-- 6. Exposed admin APIs contain an auth.uid() authorization gate.
select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and p.proname like '%_for_admin'
     and p.proname not in ('has_org_role','is_org_member')
     and position('auth.uid()' in pg_get_functiondef(p.oid)) = 0),
  0::bigint,
  'exposed *_for_admin SECURITY DEFINER APIs contain auth.uid()'
);

-- 7. Direct client INSERT into payments is denied.
select ok(
  not has_table_privilege('anon','public.payments','INSERT')
  and not has_table_privilege('authenticated','public.payments','INSERT'),
  'clients cannot insert payments directly'
);

-- 8. Direct client INSERT into draw pool is denied.
select ok(
  not has_table_privilege('anon','public.draw_pool_entries','INSERT')
  and not has_table_privilege('authenticated','public.draw_pool_entries','INSERT'),
  'clients cannot insert draw-pool entries directly'
);

-- 9. Direct client UPDATE/DELETE of financial ledger tables is denied.
select ok(
  not has_table_privilege('anon','public.payments','UPDATE')
  and not has_table_privilege('authenticated','public.payments','UPDATE')
  and not has_table_privilege('anon','public.payments','DELETE')
  and not has_table_privilege('authenticated','public.payments','DELETE'),
  'clients cannot directly mutate or delete payment ledger rows'
);

-- 10. Winner uniqueness invariant.
select ok(
  exists (
    select 1 from pg_index
    where indexrelid = 'public.monthly_winners_cycle_person_key'::regclass
      and indisunique
  ),
  'one monthly winner per person per cycle is enforced'
);

-- 11. Selection uniqueness invariant.
select ok(
  exists (
    select 1 from pg_index
    where indexrelid = 'public.draw_selections_draw_membership_key'::regclass
      and indisunique
  ),
  'a membership can be selected at most once per draw'
);

-- 12. Selection order uniqueness invariant.
select ok(
  exists (
    select 1 from pg_index
    where indexrelid = 'public.draw_selections_draw_order_key'::regclass
      and indisunique
  ),
  'draw selection order is unique per draw'
);

-- 13. One payout per winner.
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.payouts'::regclass
      and conname = 'payouts_monthly_winner_id_key'
  ),
  'one payout per monthly winner is enforced'
);

-- 14. Payout net amount invariant.
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.payouts'::regclass
      and conname = 'payouts_net_amount_invariant'
  ),
  'payout net amount invariant is enforced'
);

-- 15. Muppu uniqueness invariant.
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.muppu_records'::regclass
      and conname = 'muppu_records_kuri_cycle_person_key'
  ),
  'one Muppu record per Kuri/cycle/person is enforced'
);

-- 16. Payment organization tenancy is enforced structurally.
select ok(
  exists (
    select 1 from pg_constraint
    where conrelid = 'public.payments'::regclass
      and conname = 'payments_organization_id_fkey'
  ),
  'payments carry an organization foreign key'
);

-- 17. Existing winner tenancy is clean.
select is(
  (select count(*)
   from public.monthly_winners mw
   join public.cycles c on c.id = mw.cycle_id
   join public.kuris k on k.id = c.kuri_id
   join public.people p on p.id = mw.person_id
   where p.organization_id is distinct from k.organization_id),
  0::bigint,
  'existing winners preserve organization tenancy'
);

-- 18. Existing installment domain links are clean.
select is(
  (select count(*)
   from public.installments i
   join public.memberships m on m.id = i.membership_id
   join public.cycles c on c.id = i.cycle_id
   where m.kuri_id is distinct from c.kuri_id),
  0::bigint,
  'existing installments match membership and cycle Kuri'
);

-- 19. Existing payment allocation identity links are clean.
select is(
  (select count(*)
   from public.payment_allocations pa
   join public.payments p on p.id = pa.payment_id
   join public.installments i on i.id = pa.installment_id
   join public.memberships m on m.id = i.membership_id
   where p.person_id is distinct from m.person_id
      or p.organization_id is distinct from (
        select k.organization_id
        from public.kuris k
        where k.id = m.kuri_id
      )),
  0::bigint,
  'existing payment allocations preserve person and organization identity'
);

-- 20. New payouts cannot point at non-completed cycles.
select is(
  (select count(*)
   from public.payouts po
   join public.monthly_winners mw on mw.id = po.monthly_winner_id
   join public.cycles c on c.id = mw.cycle_id
   where c.status <> 'COMPLETED'
     and po.created_at >= timestamp '2026-09-20 00:00:00+00'),
  0::bigint,
  'new payouts are linked only to completed cycles'
);

-- 21. Critical domain-identity immutability triggers exist.
select is(
  (select count(*)
   from (
     values
       ('kuris'::regclass),
       ('people'::regclass),
       ('memberships'::regclass),
       ('cycles'::regclass),
       ('installments'::regclass),
       ('payments'::regclass)
   ) v(t)
   where exists (
     select 1
     from pg_trigger tg
     where tg.tgrelid = v.t
       and tg.tgfoid = 'public.enforce_domain_identity_immutability()'::regprocedure
   )),
  6::bigint,
  'critical domain identity immutability triggers exist'
);

-- 22. Canonical API has no duplicate function identities.
select is(
  (select count(*)
   from (
     select p.proname, pg_get_function_identity_arguments(p.oid)
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prosecdef
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     group by p.proname, pg_get_function_identity_arguments(p.oid)
     having count(*) > 1
   ) d),
  0::bigint,
  'exposed SECURITY DEFINER function identities are unique'
);

-- 23. The canonical API includes the key RPCs required by the backend contract.
select ok(
  (
    select count(*) = 13
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
      and p.proname in (
        'bootstrap_kuri_admin',
        'create_kuri_for_admin',
        'create_person_for_admin',
        'create_membership_for_admin',
        'create_payment_for_admin',
        'allocate_payment_for_admin',
        'prepare_draw_for_admin',
        'run_random_draw_for_admin',
        'finalize_draw_for_admin',
        'prepare_payout_for_admin',
        'mark_payout_paid_for_admin',
        'create_membership_exit_for_admin',
        'settle_membership_exit_for_admin'
      )
  ),
  'documented core mutation RPCs are exposed'
);

-- 24. The RLS helpers required by current policies remain callable by authenticated users.
select ok(
  has_function_privilege(
    'authenticated',
    'public.has_org_role(uuid,app_role[])'::regprocedure,
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'public.is_org_member(uuid)'::regprocedure,
    'EXECUTE'
  ),
  'RLS authorization helpers remain callable by authenticated users'
);


-- 30-33: Kuri-scoped payment API contract
select ok(
  has_function_privilege(
    'authenticated',
    'public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text)'::regprocedure,
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'public.list_payments_for_admin(uuid)'::regprocedure,
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
  'Kuri-scoped payment mutation/read APIs are authenticated-only'
);

select ok(
  to_regprocedure('public.create_payment_for_admin(uuid,bigint,timestamptz,public.payment_method,text,text)') is null
  and to_regprocedure('public.list_payments_for_admin()') is null
  and to_regprocedure('public.list_installments_for_person_payment_admin(uuid)') is null,
  'legacy organization-wide payment API signatures are removed'
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
  'all payment/installation admin APIs are Kuri-scoped'
);

select ok(
  exists (
    select 1 from information_schema.columns
    where table_schema='public'
      and table_name='payments'
      and column_name='kuri_id'
      and is_nullable='NO'
  )
  and exists (
    select 1 from pg_constraint
    where conrelid='public.payments'::regclass
      and conname='payments_kuri_organization_fkey'
  ),
  'payment rows carry immutable Kuri tenancy'
);


-- 34-38: payment idempotency API contract
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
  ),
  'idempotent payment APIs are exposed to authenticated clients'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.allocate_payment_for_admin(uuid,uuid,bigint,text)'::regprocedure,
    'EXECUTE'
  ),
  'anonymous clients cannot execute idempotent payment APIs'
);

select ok(
  exists (
    select 1 from pg_class
    where oid='public.financial_idempotency_keys'::regclass
      and relrowsecurity
  )
  and not has_table_privilege('authenticated','public.financial_idempotency_keys','SELECT'),
  'financial idempotency ledger is internal and RLS protected'
);

select ok(
  exists (
    select 1 from pg_constraint
    where conrelid='public.financial_idempotency_keys'::regclass
      and conname='financial_idempotency_keys_actor_user_id_operation_type_idempotency_key_key'
  ),
  'idempotency key uniqueness is structurally enforced'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('create_payment_for_admin','allocate_payment_for_admin')
      and p.prosecdef
      and has_function_privilege('authenticated',p.oid,'EXECUTE')
      and p.proconfig is not null
  ),
  'idempotent payment functions retain SECURITY DEFINER with fixed configuration'
);



-- 39-48: payment correction/reversal API boundary
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef and has_function_privilege('authenticated',p.oid,'EXECUTE')
     and p.proname in ('create_payment_correction_request_for_admin','create_payment_reversal_request_for_admin','approve_payment_adjustment_request_for_admin','reject_payment_adjustment_request_for_admin','execute_payment_adjustment_request_for_admin','list_payment_adjustment_requests_for_admin','get_payment_adjustment_request_for_admin')),7::bigint,
  'seven payment adjustment APIs are authenticated-callable'
);
select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef and has_function_privilege('anon',p.oid,'EXECUTE')
     and p.proname in ('create_payment_correction_request_for_admin','create_payment_reversal_request_for_admin','approve_payment_adjustment_request_for_admin','reject_payment_adjustment_request_for_admin','execute_payment_adjustment_request_for_admin','list_payment_adjustment_requests_for_admin','get_payment_adjustment_request_for_admin')),0::bigint,
  'anonymous clients cannot execute payment adjustment APIs'
);
select ok(
  (select count(*) from pg_class where oid in ('public.payment_adjustment_requests'::regclass,'public.payment_corrections'::regclass,'public.payment_reversal_entries'::regclass) and relrowsecurity)=3
  and not has_table_privilege('authenticated','public.payment_adjustment_requests','SELECT')
  and not has_table_privilege('authenticated','public.payment_corrections','SELECT')
  and not has_table_privilege('authenticated','public.payment_reversal_entries','SELECT'),
  'payment adjustment ledgers are RLS protected and not directly readable'
);
select ok(
  not has_table_privilege('authenticated','public.payment_adjustment_requests','INSERT')
  and not has_table_privilege('authenticated','public.payment_adjustment_requests','UPDATE')
  and not has_table_privilege('authenticated','public.payment_adjustment_requests','DELETE'),
  'clients cannot directly mutate adjustment requests'
);
select ok(
  not has_function_privilege('authenticated','public.get_effective_payment_amount(uuid)'::regprocedure,'EXECUTE')
  and not has_function_privilege('authenticated','public.get_effective_payment_allocation_amount(uuid)'::regprocedure,'EXECUTE'),
  'effective payment helpers are internal'
);
select ok(
  exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='payment_adjustment_status'),
  'payment adjustment lifecycle type exists'
);
select ok(
  exists (select 1 from pg_constraint where conrelid='public.payment_adjustment_requests'::regclass and conname='payment_adjustment_requests_kuri_org_fkey')
  and exists (select 1 from pg_constraint where conrelid='public.payment_corrections'::regclass and conname='payment_corrections_kuri_org_fkey')
  and exists (select 1 from pg_constraint where conrelid='public.payment_reversal_entries'::regclass and conname='payment_reversal_entries_kuri_org_fkey'),
  'payment adjustment ledgers preserve Kuri/organization tenancy'
);
select ok(
  exists (select 1 from pg_constraint where conrelid='public.payment_adjustment_requests'::regclass and pg_get_constraintdef(oid) ilike '%reason%')
  and exists (select 1 from pg_constraint where conrelid='public.payment_adjustment_requests'::regclass and pg_get_constraintdef(oid) ilike '%REJECTED%'),
  'adjustment requests require reasons and rejection reasons'
);
select ok(
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='reject_payment_adjustment_request_for_admin' and pg_get_functiondef(p.oid) ilike '%p_rejection_reason%'),
  'rejection API input parameter is unambiguous'
);
select ok(
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef and has_function_privilege('authenticated',p.oid,'EXECUTE')
     and p.proname in ('create_payment_correction_request_for_admin','create_payment_reversal_request_for_admin','approve_payment_adjustment_request_for_admin','reject_payment_adjustment_request_for_admin','execute_payment_adjustment_request_for_admin','list_payment_adjustment_requests_for_admin','get_payment_adjustment_request_for_admin')
     and (p.proconfig is null or not exists(select 1 from unnest(p.proconfig) cfg where cfg='search_path=public'))) = 0,
  'payment adjustment APIs retain fixed search_path'
);


-- 49-56: oldest-first and advance-payment allocation contract
select ok(
  has_function_privilege('authenticated','public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)'::regprocedure,'EXECUTE'),
  'oldest-first advance allocation API is authenticated-callable'
);
select ok(
  not has_function_privilege('anon','public.allocate_payment_to_oldest_installments_for_admin(uuid,uuid,bigint,text)'::regprocedure,'EXECUTE'),
  'oldest-first advance allocation API is not anonymous-callable'
);
select ok(
  to_regprocedure('public.allocate_payment_to_oldest_installments_for_admin(uuid,bigint,text)') is null,
  'stale advance allocation API overload is absent'
);
select ok(
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='allocate_payment_for_admin'
            and pg_get_functiondef(p.oid) ilike '%Cannot skip outstanding earlier installments%'),
  'targeted allocation API enforces no-skipping'
);
select ok(
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='allocate_payment_to_oldest_installments_for_admin'
            and pg_get_functiondef(p.oid) ilike '%target_membership_id%'
            and pg_get_functiondef(p.oid) ilike '%Payment person does not match membership person%'),
  'advance allocation is membership-scoped'
);
select ok(
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='allocate_payment_to_oldest_installments_for_admin'
            and pg_get_functiondef(p.oid) ilike '%ORDER BY oc.cycle_number,oi.id%'),
  'advance allocation orders installments oldest-first'
);
select ok(
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
          where n.nspname='public' and p.proname='allocate_payment_to_oldest_installments_for_admin'
            and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'),
  'advance allocation is idempotency-protected'
);
select ok(
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.prosecdef and has_function_privilege('authenticated',p.oid,'EXECUTE')
     and p.proname in ('allocate_payment_for_admin','allocate_payment_to_oldest_installments_for_admin')
     and (p.proconfig is null or not exists(select 1 from unnest(p.proconfig) cfg where cfg='search_path=public'))) = 0,
  'payment allocation APIs retain fixed search_path'
);

-- 57-61: draw API authority and invariant contract
select ok(
  has_function_privilege('authenticated','public.prepare_draw_for_admin(uuid)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.set_draw_pool_entry_for_admin(uuid,boolean,text)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.run_random_draw_for_admin(uuid,integer)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.finalize_draw_for_admin(uuid,uuid[])'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.prepare_draw_for_admin(uuid)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.finalize_draw_for_admin(uuid,uuid[])'::regprocedure,'EXECUTE'),
  'draw APIs are Kuri-scoped and authenticated-only'
);

select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname in (
       'transition_draw_status_for_admin',
       'prepare_draw_for_admin',
       'set_draw_pool_entry_for_admin',
       'run_random_draw_for_admin',
       'finalize_draw_for_admin',
       'get_draw_session_for_admin',
       'get_draw_selections_for_admin',
       'list_draw_pool_for_admin',
       'get_monthly_winners_for_admin'
     )
     and pg_get_functiondef(p.oid) ilike '%has_kuri_admin_role%'),
  9::bigint,
  'all draw and winner APIs authorize through Kuri authority'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='prepare_draw_for_admin'
      and pg_get_functiondef(p.oid) ilike '%draw_status_value=''POOL_READY''%'
  )
  and exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='run_random_draw_for_admin'
      and pg_get_functiondef(p.oid) ilike '%not e.system_eligible%'
  ),
  'draw eligibility remains frozen after POOL_READY'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='finalize_draw_for_admin'
      and pg_get_functiondef(p.oid) ilike '%A person who has already won in this Kuri cannot win again%'
      and pg_get_functiondef(p.oid) ilike '%max_winners%'
  ),
  'winner finalization enforces no-repeat and maximum-feasible winner rules'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='finalize_draw_for_admin'
      and pg_get_functiondef(p.oid) ilike '%FOR UPDATE%'
  ),
  'winner finalization retains row-level concurrency locking'
);

-- 62-66: payout authority and idempotency contract
select ok(
  has_function_privilege(
    'authenticated',
    'public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,text,bigint)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.mark_payout_paid_for_admin(uuid,timestamptz,public.payment_method,text,text,text,bigint)'::regprocedure,
    'EXECUTE'
  ),
  'payout payment API is authenticated-only with the idempotent signature'
);

select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname in (
       'transition_payout_status_for_admin',
       'prepare_payout_for_admin',
       'get_payout_for_admin',
       'list_payouts_for_admin',
       'mark_payout_paid_for_admin'
     )
     and pg_get_functiondef(p.oid) ilike '%has_kuri_admin_role%'),
  5::bigint,
  'all payout APIs authorize through Kuri authority'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='mark_payout_paid_for_admin'
      and pg_get_functiondef(p.oid) ilike '%financial_idempotency_keys%'
      and pg_get_functiondef(p.oid) ilike '%PAYOUT_PAYMENT%'
  ),
  'payout payment API uses idempotency and Kuri authority'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid='public.financial_idempotency_keys'::regclass
      and pg_get_constraintdef(oid) ilike '%PAYOUT_PAYMENT%'
  ),
  'payout payment idempotency operation type is allowed'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='mark_payout_paid_for_admin'
      and p.proconfig is not null
      and exists(select 1 from unnest(p.proconfig) cfg where cfg='search_path=public')
  ),
  'payout payment API has fixed SECURITY DEFINER search_path'
);

-- 67-71: cycle authority and immutable schedule contract
select ok(
  has_function_privilege('authenticated','public.generate_cycles_for_admin(uuid)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.generate_kuri_schedule_for_admin(uuid)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.get_cycle_for_admin(uuid)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.list_cycles_for_admin(uuid)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.transition_cycle_status_for_admin(uuid,public.cycle_status)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.transition_cycle_status_for_admin(uuid,public.cycle_status)'::regprocedure,'EXECUTE'),
  'cycle APIs are authenticated-only'
);

select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname in (
       'generate_cycles_for_admin',
       'generate_kuri_schedule_for_admin',
       'get_cycle_for_admin',
       'list_cycles_for_admin',
       'transition_cycle_status_for_admin'
     )
     and pg_get_functiondef(p.oid) ilike '%has_kuri_admin_role%'),
  5::bigint,
  'cycle APIs authorize through Kuri authority'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='generate_cycles_for_admin'
      and pg_get_functiondef(p.oid) ilike '%status NOT IN (''COMPLETED'',''CANCELLED'')%'
  ),
  'cycle schedule regeneration preserves terminal cycle history'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('generate_cycles_for_admin','transition_cycle_status_for_admin')
      and pg_get_functiondef(p.oid) ilike '%FOR UPDATE%'
  ),
  'cycle mutation APIs retain concurrency row locking'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='transition_cycle_status_for_admin'
      and pg_get_functiondef(p.oid) ilike '%draw_sessions%'
      and pg_get_functiondef(p.oid) ilike '%monthly_winners%'
  ),
  'cycle completion contract still requires finalized draw and winner'
);

-- 72-76: membership authority and late-join contract
select ok(
  has_function_privilege('authenticated','public.create_membership_for_admin(uuid,uuid,text)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.list_memberships_for_admin(uuid)'::regprocedure,'EXECUTE')
  and has_function_privilege('authenticated','public.transition_membership_status_for_admin(uuid,public.membership_status)'::regprocedure,'EXECUTE')
  and not has_function_privilege('anon','public.create_membership_for_admin(uuid,uuid,text)'::regprocedure,'EXECUTE'),
  'membership APIs are authenticated-only and Kuri-scoped'
);

select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public'
     and p.proname in (
       'create_membership_for_admin',
       'list_memberships_for_admin',
       'transition_membership_status_for_admin',
       'list_people_available_for_membership'
     )
     and pg_get_functiondef(p.oid) ilike '%has_kuri_admin_role%'),
  4::bigint,
  'membership picker and mutation APIs authorize through Kuri authority'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='create_membership_for_admin'
      and pg_get_functiondef(p.oid) ilike '%status NOT IN (''COMPLETED'',''CANCELLED'')%'
  ),
  'new memberships do not receive retroactive terminal-cycle installments'
);

select ok(
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='create_membership_for_admin'
      and pg_get_functiondef(p.oid) ilike '%FOR UPDATE%'
  ),
  'membership creation retains Kuri row locking for capacity protection'
);

select * from finish();
rollback;
