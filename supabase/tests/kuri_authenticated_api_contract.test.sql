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

select plan(27);

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

-- 3. The reviewed authenticated SECURITY DEFINER API surface is exactly 65.
-- Internal state-machine trigger helpers are deliberately excluded from the
-- client-facing SECURITY DEFINER API boundary.
select is(
  (select count(*)
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  70::bigint,
  'authenticated SECURITY DEFINER API surface includes the reviewed APIs plus explicit organization context'
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

select * from finish();
rollback;
