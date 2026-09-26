-- WINNER-002: system suggested winner count contract

begin;

select plan(5);

select ok(
  to_regprocedure('public.suggest_winner_count_for_admin(uuid)') is not null,
  'system suggested winner count API exists'
);

select ok(
  pg_get_functiondef('public.suggest_winner_count_for_admin(uuid)'::regprocedure)
    ilike '%v_unwon_member_count-(v_remaining_cycles-1)%',
  'suggestion uses maximum-feasible winner formula'
);

select ok(
  pg_get_functiondef('public.suggest_winner_count_for_admin(uuid)'::regprocedure)
    ilike '%Insufficient remaining current holders%',
  'suggestion rejects insufficient members/cycles'
);

select ok(
  pg_get_functiondef('public.suggest_winner_count_for_admin(uuid)'::regprocedure)
    ilike '%status=''ACTIVE''%',
  'suggestion counts only active memberships'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.suggest_winner_count_for_admin(uuid)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.suggest_winner_count_for_admin(uuid)'::regprocedure,
    'EXECUTE'
  ),
  'system suggestion is authenticated-only'
);

select * from finish();

rollback;
