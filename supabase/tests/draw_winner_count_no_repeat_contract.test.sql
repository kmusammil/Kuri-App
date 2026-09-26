-- DRAW-003: winner-count and no-repeat contract coverage

begin;

select plan(8);

select ok(
  to_regprocedure('public.finalize_draw_for_admin(uuid,uuid[],text)') is not null,
  'winner finalization API exists'
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
  'winner finalization is authenticated-only'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%cardinality(final_membership_ids)<1%',
  'at least one winner is required'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%Duplicate winner memberships are not allowed%',
  'duplicate winner selections are rejected'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%already won in this Kuri cannot win again%',
  'repeat winners are rejected'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%v_unwon_member_count<v_remaining_cycles%',
  'insufficient remaining members versus cycles is rejected'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%v_max_winners:=v_unwon_member_count-(v_remaining_cycles-1)%'
    and pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
      ilike '%Selected winner count exceeds the maximum feasible winner count%',
  'maximum feasible winner count is enforced'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%Only one winner per current holder can be finalized in a cycle%',
  'one winner per current holder per cycle is enforced'
);

select * from finish();

rollback;
