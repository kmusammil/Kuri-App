begin;
create table if not exists public.security_event_types (
 event_type text primary key,
 severity text not null check (severity in ('WARNING','HIGH','CRITICAL')),
 description text not null,
 retention_days integer not null check (retention_days between 1 and 3650),
 enabled boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
insert into public.security_event_types(event_type,severity,description,retention_days) values
('ADMIN_POSITION_GRANTED','HIGH','An organization member was granted the ADMIN role.',365),
('ORGANIZATION_MAIN_ADMIN_TRANSFER','CRITICAL','Organization MAIN_ADMIN authority was transferred.',1095),
('KURI_MAIN_ADMIN_TRANSFER','CRITICAL','Kuri MAIN_ADMIN authority was transferred.',1095),
('KURI_ADMIN_LEGACY_RECOVERY','HIGH','Legacy Kuri administrator recovery or restoration occurred.',1095)
on conflict(event_type) do update set severity=excluded.severity,description=excluded.description,retention_days=excluded.retention_days,enabled=true,updated_at=now();
alter table public.security_event_types enable row level security;
revoke all on table public.security_event_types from public,anon,authenticated;

create table if not exists public.security_events (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 kuri_id uuid references public.kuris(id) on delete restrict,
 event_type text not null references public.security_event_types(event_type) on delete restrict,
 severity text not null check (severity in ('WARNING','HIGH','CRITICAL')),
 actor_user_id uuid references public.users(id) on delete set null,
 subject_user_id uuid references public.users(id) on delete set null,
 aggregate_type text,
 aggregate_id uuid,
 source_audit_log_id uuid not null unique references public.audit_logs(id) on delete restrict,
 payload jsonb not null default '{}'::jsonb,
 idempotency_key text not null,
 occurred_at timestamptz not null,
 retention_until timestamptz not null,
 created_at timestamptz not null default now(),
 constraint security_events_payload_object_check check(jsonb_typeof(payload)='object')
);
create unique index if not exists security_events_org_idempotency_key on public.security_events(organization_id,idempotency_key);
create index if not exists security_events_org_created_idx on public.security_events(organization_id,created_at desc);
create index if not exists security_events_org_severity_idx on public.security_events(organization_id,severity,created_at desc);
alter table public.security_events enable row level security;
revoke all on table public.security_events from public,anon,authenticated;
grant select on table public.security_events to authenticated;
create policy security_events_select_admin on public.security_events for select to authenticated using (
 exists(select 1 from public.organization_users ou where ou.organization_id=security_events.organization_id and ou.user_id=(select auth.uid()) and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]))
);

create or replace function public.emit_admin_security_notification_event(target_security_event_id uuid)
returns uuid language plpgsql security definer set search_path=public as $function$
declare e public.security_events%rowtype; v_id uuid;
begin
 select * into e from public.security_events where id=target_security_event_id;
 if not found then return null; end if;
 v_id:=public.emit_organization_notification_event_internal(
   e.organization_id,'ADMIN_SECURITY',e.aggregate_type,e.aggregate_id,
   jsonb_build_object('security_event_id',e.id,'event_type',e.event_type,'severity',e.severity,'actor_user_id',e.actor_user_id,'subject_user_id',e.subject_user_id,'kuri_id',e.kuri_id,'payload',e.payload,'occurred_at',e.occurred_at),
   'admin-security:'||e.id::text,e.actor_user_id);
 return v_id;
end;
$function$;

create or replace function public.emit_security_event_from_audit_log()
returns trigger language plpgsql security definer set search_path=public as $function$
declare mapped_event_type text; event_def public.security_event_types%rowtype; target_kuri_id uuid; target_subject_user_id uuid; event_id uuid;
begin
 mapped_event_type:=case new.action
  when 'ADMIN_POSITION_REQUEST_APPROVED' then 'ADMIN_POSITION_GRANTED'
  when 'ORGANIZATION_MAIN_ADMIN_TRANSFER' then 'ORGANIZATION_MAIN_ADMIN_TRANSFER'
  when 'KURI_MAIN_ADMIN_TRANSFER' then 'KURI_MAIN_ADMIN_TRANSFER'
  when 'KURI_ADMIN_LEGACY_RECOVERY' then 'KURI_ADMIN_LEGACY_RECOVERY'
  else null end;
 if mapped_event_type is null then return new; end if;
 select * into event_def from public.security_event_types where event_type=mapped_event_type and enabled;
 if not found then return new; end if;
 target_kuri_id:=case when new.action='KURI_MAIN_ADMIN_TRANSFER' then nullif(coalesce(new.new_data->>'kuri_id',new.old_data->>'kuri_id'),'')::uuid else null end;
 target_subject_user_id:=case
  when new.action='ADMIN_POSITION_REQUEST_APPROVED' then nullif(new.new_data->>'requester_user_id','')::uuid
  when new.action in ('ORGANIZATION_MAIN_ADMIN_TRANSFER','KURI_MAIN_ADMIN_TRANSFER','KURI_ADMIN_LEGACY_RECOVERY') then new.entity_id
  else null end;
 insert into public.security_events(
  organization_id,kuri_id,event_type,severity,actor_user_id,subject_user_id,aggregate_type,aggregate_id,source_audit_log_id,payload,idempotency_key,occurred_at,retention_until)
 values(
  new.organization_id,target_kuri_id,event_def.event_type,event_def.severity,new.user_id,target_subject_user_id,new.entity_type,new.entity_id,new.id,
  jsonb_build_object('audit_action',new.action,'audit_log_id',new.id,'old_data',coalesce(new.old_data,'{}'::jsonb),'new_data',coalesce(new.new_data,'{}'::jsonb),'reason',new.reason),
  'admin-security:'||new.id::text,new.created_at,new.created_at+make_interval(days=>event_def.retention_days))
 on conflict(source_audit_log_id) do nothing
 returning id into event_id;
 if event_id is not null then perform public.emit_admin_security_notification_event(event_id); end if;
 return new;
end;
$function$;

drop trigger if exists emit_security_event_from_audit_log on public.audit_logs;
create trigger emit_security_event_from_audit_log after insert on public.audit_logs for each row execute function public.emit_security_event_from_audit_log();

revoke all on function public.emit_admin_security_notification_event(uuid) from public,anon,authenticated;
revoke all on function public.emit_security_event_from_audit_log() from public,anon,authenticated;
commit;