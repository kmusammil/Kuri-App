begin;

select plan(11);

select ok(
  to_regclass('public.organization_admin_position_requests') is not null,
  'Admin position request table exists'
);

select ok(
  exists (
    select 1
    from pg_type t
    join pg_enum e on e.enumtypid=t.oid
    where t.typnamespace='public'::regnamespace
      and t.typname='admin_position_request_status'
      and e.enumlabel in ('PENDING','APPROVED','REJECTED','CANCELLED')
  ),
  'Admin position request status enum exists'
);

select ok(
  exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname='organization_admin_position_requests'
      and c.relrowsecurity
  ),
  'Admin position request table has RLS enabled'
);

select ok(
  exists (
    select 1
    from pg_index i
    where i.indexrelid='public.organization_admin_position_requests_pending_key'::regclass
      and i.indisunique
      and pg_get_expr(i.indpred,i.indrelid) = '(status = ''PENDING''::public.admin_position_request_status)'
  ),
  'Only one pending request per organization/requester is enforced'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.create_admin_position_request_for_user(uuid)'::regprocedure,
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'public.approve_admin_position_request_for_admin(uuid)'::regprocedure,
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'public.reject_admin_position_request_for_admin(uuid,text)'::regprocedure,
    'EXECUTE'
  )
  and has_function_privilege(
    'authenticated',
    'public.cancel_admin_position_request_for_user(uuid)'::regprocedure,
    'EXECUTE'
  ),
  'Admin position request APIs are authenticated-only'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.create_admin_position_request_for_user(uuid)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.approve_admin_position_request_for_admin(uuid)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.reject_admin_position_request_for_admin(uuid,text)'::regprocedure,
    'EXECUTE'
  )
  and not has_function_privilege(
    'anon',
    'public.cancel_admin_position_request_for_user(uuid)'::regprocedure,
    'EXECUTE'
  ),
  'Anonymous execution is disabled'
);

select ok(
  not has_table_privilege('anon','public.organization_admin_position_requests','INSERT')
  and not has_table_privilege('authenticated','public.organization_admin_position_requests','INSERT')
  and not has_table_privilege('anon','public.organization_admin_position_requests','UPDATE')
  and not has_table_privilege('authenticated','public.organization_admin_position_requests','UPDATE')
  and not has_table_privilege('anon','public.organization_admin_position_requests','DELETE')
  and not has_table_privilege('authenticated','public.organization_admin_position_requests','DELETE'),
  'Direct client mutation of request records is disabled'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='emit_admin_position_request_notification_event'
      and p.prosecdef
  )
  and exists (
    select 1
    from pg_trigger t
    where t.tgrelid='public.organization_admin_position_requests'::regclass
      and t.tgname='emit_admin_position_request_notification_event'
  ),
  'Admin position requests produce the notification event through a trigger'
);

select ok(
  exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname='emit_organization_notification_event_internal'
      and p.prosecdef
      and not has_function_privilege('authenticated',p.oid,'EXECUTE')
  ),
  'Organization notification emitter is internal-only'
);

select ok(
  exists (
    select 1
    from pg_policy
    where schemaname='public'
      and tablename='organization_admin_position_requests'
      and policyname='organization_admin_position_requests_select'
      and cmd='SELECT'
  ),
  'Request visibility is protected by an organization-scoped SELECT policy'
);

select is(
  (select count(*)
   from public.notification_event_policies
   where event_type='ADMIN_POSITION_REQUEST'
     and actor_policy='EXCLUDE'
     and no_user_policy='NO_APP_NOTIFICATION'),
  1::bigint,
  'ADMIN_POSITION_REQUEST notification policy remains configured'
);

select * from finish();
rollback;
