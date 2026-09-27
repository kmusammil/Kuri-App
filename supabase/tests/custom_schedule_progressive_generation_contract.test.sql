begin;
select plan(5);
select ok(
  pg_get_functiondef('public.generate_kuri_schedule_for_admin(uuid)'::regprocedure)
  like '%if kuri_row.schedule_mode = ''CUSTOM''::public.kuri_schedule_mode then%',
  'generator has a CUSTOM scheduling branch'
);
select ok(
  pg_get_functiondef('public.generate_kuri_schedule_for_admin(uuid)'::regprocedure)
  like '%Define at least one custom cycle%',
  'CUSTOM generation allows progressive schedule definition'
);
select ok(
  pg_get_functiondef('public.generate_kuri_schedule_for_admin(uuid)'::regprocedure)
  not like '%Custom schedule must define exactly % cycles%',
  'generator no longer requires all custom cycles upfront'
);
select ok(
  pg_get_functiondef('public.generate_kuri_schedule_for_admin(uuid)'::regprocedure)
  not like '%Custom schedule cannot contain more cycles than current Kuri membership%',
  'CUSTOM generation no longer couples cycle count to membership count'
);
select ok(
  pg_get_functiondef('public.generate_kuri_schedule_for_admin(uuid)'::regprocedure)
  like '%define cycles consecutively%',
  'custom schedules must remain contiguous'
);
select * from finish();
rollback;