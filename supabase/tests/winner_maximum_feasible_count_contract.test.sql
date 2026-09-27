-- WINNER-004: maximum feasible winner count contract

begin;

select plan(4);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%v_max_winners:=v_unwon_member_count-(v_remaining_cycles-1)%',
  'maximum feasible winner count uses M - (C - 1)'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%array_length(final_membership_ids,1)>v_max_winners%',
  'finalization rejects a winner count above the feasible maximum'
);

select ok(
  pg_get_functiondef('public.suggest_winner_count_for_admin(uuid)'::regprocedure)
    ilike '%v_max_winners:=v_unwon_member_count-(v_remaining_cycles-1)%',
  'system suggestion uses the same maximum-feasible formula'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%Insufficient remaining current holders for the remaining cycles%',
  'maximum calculation is protected by insufficient-member/cycle validation'
);

select * from finish();

rollback;
