begin;
select plan(5);
select is((select count(*) from pg_trigger where tgrelid='public.memberships'::regclass and tgname='audit_membership_creation' and not tgisinternal),1::bigint,'membership audit trigger exists');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='audit_membership_creation'),1::bigint,'membership audit helper exists');
select ok(not has_function_privilege('anon','public.audit_membership_creation()','EXECUTE'),'audit helper blocks anon');
select ok(not has_function_privilege('authenticated','public.audit_membership_creation()','EXECUTE'),'audit helper is internal');
select ok(pg_get_functiondef('public.audit_membership_creation()'::regprocedure) like '%membership_created%','audit event is membership-specific');
select * from finish();
rollback;