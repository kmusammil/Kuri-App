-- MEMBERSHIP-005 contract: historical finalized draws cannot accept late memberships

select plan(5);

select ok(
  exists (
    select 1
    from pg_trigger t
    where t.tgrelid='public.draw_pool_entries'::regclass
      and t.tgname='draw_pool_membership_history_guard'
      and not t.tgisinternal
  ),
  'draw pool has historical membership guard'
);

select ok(
  pg_get_functiondef('public.enforce_draw_pool_membership_history()'::regprocedure)
    ilike '%status in (''FINALIZED'',''CANCELLED'')%'
    and pg_get_functiondef('public.enforce_draw_pool_membership_history()'::regprocedure)
    ilike '%membership_joined_at > session_started_at%',
  'guard rejects finalized/cancelled pools and memberships joined after draw start'
);

select is(
  (select count(*) from public.draw_pool_entries e
   join public.draw_sessions d on d.id=e.draw_session_id
   join public.memberships m on m.id=e.membership_id
   where m.joined_at > d.started_at),
  0::bigint,
  'existing draw pools contain no membership created after draw start'
);

select ok(
  pg_get_functiondef('public.prepare_draw_for_admin(uuid)'::regprocedure)
    ilike '%cycle_status_value not in (''PAYMENT_CLOSED'',''DRAW_PENDING'')%',
  'draw preparation cannot reopen completed historical cycles'
);

select ok(
  pg_get_functiondef('public.enforce_draw_pool_membership_history()'::regprocedure)
    ilike '%security definer%'
    and pg_get_functiondef('public.enforce_draw_pool_membership_history()'::regprocedure)
    ilike '%set search_path to ''''%',
  'historical draw guard is hardened as SECURITY DEFINER with empty search_path'
);

select * from finish();
