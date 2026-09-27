begin;

select plan(14);

select ok(to_regclass('public.kuri_announcements') is not null,'announcement table exists');
select ok(to_regclass('public.kuri_announcement_versions') is not null,'announcement version table exists');
select ok(exists(select 1 from pg_type t join pg_enum e on e.enumtypid=t.oid where t.typnamespace='public'::regnamespace and t.typname='kuri_announcement_status' and e.enumlabel='DRAFT'),'announcement status enum exists');
select ok(exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='kuri_announcements' and c.relrowsecurity),'announcement RLS enabled');
select ok(not has_table_privilege('anon','public.kuri_announcements','INSERT') and not has_table_privilege('authenticated','public.kuri_announcements','INSERT'),'direct announcement insert disabled');
select ok(has_function_privilege('authenticated','public.create_kuri_announcement_for_admin(uuid,text,text,timestamptz)'::regprocedure),'create RPC authenticated');
select ok(has_function_privilege('authenticated','public.update_kuri_announcement_for_admin(uuid,text,text,timestamptz,timestamptz)'::regprocedure),'update RPC authenticated');
select ok(has_function_privilege('authenticated','public.publish_kuri_announcement_for_admin(uuid)'::regprocedure),'publish RPC authenticated');
select ok(has_function_privilege('authenticated','public.withdraw_kuri_announcement_for_admin(uuid)'::regprocedure),'withdraw RPC authenticated');
select ok(not has_function_privilege('anon','public.publish_kuri_announcement_for_admin(uuid)'::regprocedure),'anonymous publish disabled');
select ok(exists(select 1 from pg_trigger where tgrelid='public.kuri_announcements'::regclass and tgname='emit_kuri_announcement_notification_event'),'announcement notification trigger exists');
select ok(exists(select 1 from cron.job where jobname='kuri-announcement-state-processor' and schedule='* * * * *'),'announcement state cron exists');
select ok(exists(select 1 from public.notification_event_policies where event_type='KURI_ANNOUNCEMENT' and category='BROADCAST' and timing_kind='BROADCAST'),'KURI_ANNOUNCEMENT policy exists');
select ok(exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='emit_kuri_announcement_notification_event' and p.prosecdef and p.proconfig=array['search_path=public']),'announcement trigger function hardened');

select * from finish();
rollback;