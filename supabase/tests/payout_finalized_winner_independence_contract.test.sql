-- PAYOUT-003: finalized winner remains independent of payout status

begin;

select plan(5);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%insert into public.monthly_winners%'
    and pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    ilike '%transition_cycle_status_for_admin(target_cycle_id,''COMPLETED'')%',
  'winner finalization persists the winner independently of payout preparation'
);

select ok(
  exists (
    select 1 from pg_constraint c
    join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='monthly_winners'
      and c.conname='monthly_winners_pkey'
  ),
  'finalized winners have independent persistent records'
);

select ok(
  pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
    ilike '%insert into public.payouts%'
    and pg_get_functiondef('public.prepare_payout_for_admin(uuid)'::regprocedure)
    ilike '%status< >''PENDING''%',
  'payout preparation is downstream from an already-finalized winner'
);

select ok(
  pg_get_functiondef('public.transition_payout_status_for_admin(uuid,payout_status)'::regprocedure)
    ilike '%PENDING'' AND target_status IN (''PROCESSING'',''CANCELLED'')%'
    and pg_get_functiondef('public.transition_payout_status_for_admin(uuid,payout_status)'::regprocedure)
    ilike '%PROCESSING'' AND target_status IN (''PAID'',''CANCELLED'')%',
  'payout status transitions cannot mutate or reverse winner finalization'
);

select ok(
  exists (
    select 1 from pg_constraint c
    join pg_class r on r.oid=c.conrelid
    join pg_namespace n on n.oid=r.relnamespace
    where n.nspname='public' and r.relname='monthly_winners'
      and c.conname='monthly_winners_cycle_id_fkey'
  ),
  'winner record remains anchored to its finalized cycle'
);

select * from finish();

rollback;
