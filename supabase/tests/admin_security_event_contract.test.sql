begin;
select plan(11);
select ok(to_regclass('public.security_event_types') is not null,'catalog exists');
select ok(to_regclass('public.security_events') is not null,'security events table exists');
select ok((select count(*) from public.security_event_types where event_type in ('ADMIN_POSITION_GRANTED','ORGANIZATION_MAIN_ADMIN_TRANSFER','KURI_MAIN_ADMIN_TRANSFER','KURI_ADMIN_LEGACY_RECOVERY'))=4,'explicit catalog populated');
select ok(exists(select 1 from pg_policies where schemaname='public' and tablename='security_events' and policyname='security_events_select_admin'),'admin read policy exists');
select ok(not has_table_privilege('anon','public.security_events','INSERT'),'anon insert disabled');
select ok(not has_table_privilege('authenticated','public.security_events','INSERT'),'authenticated insert disabled');
select ok(exists(select 1 from pg_trigger where tgrelid='public.audit_logs'::regclass and tgname='emit_security_event_from_audit_log'),'audit trigger exists');
select ok(exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='emit_security_event_from_audit_log' and p.prosecdef and p.proconfig=array['search_path=public']),'trigger hardened');
select ok(not has_function_privilege('anon','public.emit_admin_security_notification_event(uuid)'::regprocedure),'notification emitter anon disabled');
select ok(exists(select 1 from public.notification_event_policies where event_type='ADMIN_SECURITY'),'ADMIN_SECURITY policy exists');
insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,new_data,reason)
select ou.organization_id,ou.user_id,'ORGANIZATION_MAIN_ADMIN_TRANSFER','organization_users',ou.user_id,jsonb_build_object('new_main_admin_user_id',ou.user_id),'security-event contract test'
from public.organization_users ou limit 1;
select ok((select count(*) from public.security_events where source_audit_log_id=(select id from public.audit_logs where reason='security-event contract test' order by created_at desc limit 1))=1,'mapped audit action creates security event');
select * from finish();
rollback;