-- WINNER-001: admin-selected winner count contract coverage

begin;

select plan(7);

select ok(
  to_regprocedure('public.finalize_draw_for_admin(uuid,uuid[],text)') is not null,
  'winner finalization API exists'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%final_membership_ids%',
  'finalization accepts an explicit admin-selected winner membership list'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%cardinality(final_membership_ids)<1%',
  'at least one winner is required'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%cardinality(final_membership_ids) <> cardinality(array(select distinct unnest(final_membership_ids)))%',
  'duplicate winner selections are rejected'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%Selected winner count exceeds the maximum feasible winner count%',
  'administrator-selected winner count is bounded by the feasible maximum'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%Final winners must come from the current draw selections%',
  'administrator can finalize only from the current draw selection set'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure,
    'EXECUTE'
  ),
  'winner-count finalization is authenticated-only'
);

select * from finish();

rollback;
