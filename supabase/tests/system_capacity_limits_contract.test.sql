begin;

select plan(9);
select has_table('public', 'system_capacity_limits', 'central capacity table exists');
select is((select max_members_per_kuri from public.system_capacity_limits where id = true), 250, 'maximum members per Kuri is 250');
select is((select max_cycles_per_kuri from public.system_capacity_limits where id = true), 36, 'maximum cycles per Kuri is 36');
select is((select max_kuris_per_organization from public.system_capacity_limits where id = true), 10, 'maximum Kuris per organization is 10');
select is((select count(*) from pg_trigger where tgname = 'enforce_system_capacity_limits'), 1::bigint, 'capacity trigger exists');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.system_capacity_limits'::regclass and conname = 'system_capacity_limits_max_members_per_kuri_check'), 'capacity values are not duplicated as per-value constraints');
select ok(not has_function_privilege('anon', 'public.enforce_system_capacity_limits()', 'EXECUTE'), 'capacity helper is not anonymously executable');
select ok(not has_function_privilege('authenticated', 'public.enforce_system_capacity_limits()', 'EXECUTE'), 'capacity helper is not client-executable');
select ok(not has_table_privilege('authenticated', 'public.system_capacity_limits', 'SELECT'), 'capacity configuration is not client-readable');
select * from finish();

rollback;
