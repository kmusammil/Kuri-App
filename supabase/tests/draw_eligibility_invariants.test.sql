-- DRAW-004: final draw eligibility invariant contract coverage

begin;

select plan(10);

select ok(
  to_regprocedure('public.prepare_draw_for_admin(uuid)') is not null,
  'draw preparation API exists'
);

select ok(
  pg_get_functiondef('public.prepare_draw_for_admin(uuid)'::regprocedure)
    ilike '%i.status IN (''PAID'',''PAID_LATE'')%',
  'PAID and PAID_LATE are system-eligible payment states'
);

select ok(
  pg_get_functiondef('public.prepare_draw_for_admin(uuid)'::regprocedure)
    ilike '%m.status=''ACTIVE''%',
  'only ACTIVE memberships can be system-eligible'
);

select ok(
  pg_get_functiondef('public.prepare_draw_for_admin(uuid)'::regprocedure)
    ilike '%NOT EXISTS(%'
    and pg_get_functiondef('public.prepare_draw_for_admin(uuid)'::regprocedure)
      ilike '%membership_exits%',
  'verified-deceased memberships are excluded from system eligibility'
);

select ok(
  pg_get_functiondef('public.prepare_draw_for_admin(uuid)'::regprocedure)
    ilike '%ON CONFLICT(draw_session_id,membership_id) DO NOTHING%',
  'draw preparation preserves one pool entry per membership'
);

select ok(
  pg_get_functiondef('public.prepare_draw_for_admin(uuid)'::regprocedure)
    ilike '%PERFORM public.transition_draw_status_for_admin(session_id,''POOL_READY'')%',
  'eligibility snapshot is frozen by transitioning the draw to POOL_READY'
);

select ok(
  pg_get_functiondef('public.set_draw_pool_entry_for_admin(uuid,boolean,text)'::regprocedure)
    ilike '%session_status<>''POOL_READY''%',
  'pool overrides are only available while POOL_READY'
);

select ok(
  pg_get_functiondef('public.run_random_draw_for_admin(uuid,integer,text)'::regprocedure)
    ilike '%e.admin_included%'
    and pg_get_functiondef('public.run_random_draw_for_admin(uuid,integer,text)'::regprocedure)
      ilike '%NOT e.system_eligible%',
  'final draw candidates respect the frozen system eligibility snapshot'
);

select ok(
  pg_get_functiondef('public.enforce_draw_pool_eligibility_freeze()'::regprocedure)
    ilike '%POOL_READY%'
    and pg_get_functiondef('public.enforce_draw_pool_eligibility_freeze()'::regprocedure)
      ilike '%Draw eligibility is frozen%',
  'database trigger prevents eligibility changes after POOL_READY'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.enforce_draw_pool_eligibility_freeze()'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.enforce_draw_pool_eligibility_freeze()'::regprocedure,
    'EXECUTE'
  ),
  'eligibility-freeze trigger function is not anonymously executable'
);

select * from finish();

rollback;
