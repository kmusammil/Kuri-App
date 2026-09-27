-- WINNER-005: insufficient remaining members/cycles contract

begin;

select plan(4);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%v_unwon_member_count<v_remaining_cycles%',
  'winner finalization rejects M < C'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%repeating winners is not allowed%',
  'insufficient remaining members never causes winner repetition'
);

select ok(
  pg_get_functiondef('public.suggest_winner_count_for_admin(uuid)'::regprocedure)
    ilike '%v_unwon_member_count<v_remaining_cycles%',
  'system suggestion rejects M < C'
);

select ok(
  pg_get_functiondef('public.suggest_winner_count_for_admin(uuid)'::regprocedure)
    ilike '%Unable to determine a valid suggested winner count%',
  'suggestion cannot return an invalid zero/negative winner count'
);

select * from finish();

rollback;
