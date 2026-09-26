-- WINNER-006: finalized winner immutability contract

begin;

select plan(5);

select ok(
  to_regprocedure('public.enforce_finalized_winner_immutability()') is not null,
  'winner immutability trigger function exists'
);

select ok(
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='monthly_winners'
      and t.tgname='monthly_winners_immutability'
      and not t.tgisinternal
  ),
  'monthly_winners has an immutability trigger'
);

select ok(
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='monthly_winner_memberships'
      and t.tgname='monthly_winner_memberships_immutability'
      and not t.tgisinternal
  ),
  'monthly_winner_memberships has an immutability trigger'
);

select ok(
  pg_get_functiondef('public.enforce_finalized_winner_immutability()'::regprocedure)
    ilike '%Finalized winner records are immutable%',
  'winner mutation attempts are rejected'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.enforce_finalized_winner_immutability()'::regprocedure,
    'EXECUTE'
  ),
  'winner immutability function is not anonymously executable'
);

select * from finish();

rollback;
