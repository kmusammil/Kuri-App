begin;
select plan(4);
select ok(
  (select max_members_per_kuri::bigint * max_cycles_per_kuri::bigint
   from public.system_capacity_limits limit 1) <= 9000,
  'membership x cycle capacity envelope is at most 9000'
);
select is(
  (select max_members_per_kuri from public.system_capacity_limits limit 1),
  250,
  'maximum members remains 250'
);
select is(
  (select max_cycles_per_kuri from public.system_capacity_limits limit 1),
  36,
  'maximum cycles remains 36'
);
select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid='public.system_capacity_limits'::regclass
      and conname='system_capacity_membership_cycle_amplification_check'
  ),
  'combined amplification guard exists'
);
select * from finish();
rollback;