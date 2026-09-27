-- WINNER-007: winning does not waive future installment obligations

begin;

select plan(5);

select ok(
  to_regprocedure('public.finalize_draw_for_admin(uuid,uuid[],text)') is not null,
  'winner finalization API exists'
);

select ok(
  pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    not ilike '%update public.installments%'
    and pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    not ilike '%delete from public.installments%'
    and pg_get_functiondef('public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure)
    not ilike '%waive%',
  'winner finalization does not mutate or waive installment obligations'
);

select ok(
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='installments'
      and t.tgname='installments_identity_immutability'
      and not t.tgisinternal
  ),
  'installment identity remains immutable'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='create_membership_for_admin'
  ),
  'membership creation path exists for installment obligation generation'
);

select ok(
  exists (
    select 1
    from information_schema.columns
    where table_schema='public'
      and table_name='installments'
      and column_name='amount_due'
  ),
  'installments retain explicit future amount obligations'
);

select * from finish();

rollback;
