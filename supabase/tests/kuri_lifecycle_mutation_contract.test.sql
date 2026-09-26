select plan(4);

select ok(
  exists (
    select 1 from pg_trigger
    where tgrelid='public.kuris'::regclass
      and tgname='kuri_lifecycle_mutation_lock'
      and not tgisinternal
  ),
  'Kuri lifecycle mutation lock trigger exists'
);

select ok(
  pg_get_functiondef('public.enforce_kuri_lifecycle_mutation_lock()'::regprocedure)
    ilike '%old.status in (''ACTIVE'',''COMPLETED'',''ARCHIVED'')%',
  'core Kuri configuration is locked after activation'
);

select ok(
  pg_get_functiondef('public.enforce_kuri_lifecycle_mutation_lock()'::regprocedure)
    ilike '%old.status=''ARCHIVED''%',
  'archived Kuri lifecycle timestamps are immutable'
);

select ok(
  pg_get_functiondef('public.enforce_kuri_lifecycle_mutation_lock()'::regprocedure)
    ilike '%security definer%'
    and pg_get_functiondef('public.enforce_kuri_lifecycle_mutation_lock()'::regprocedure)
    ilike '%set search_path to ''''%',
  'lifecycle lock is hardened as SECURITY DEFINER with empty search_path'
);

select * from finish();
