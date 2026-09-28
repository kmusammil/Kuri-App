-- Admin/security workflow reconciliation batch.
-- Ported from main-side admin position request, Kuri announcement,
-- announcement RLS scope hardening, and admin security event migrations.

begin;

do $$
begin
  create type public.admin_position_request_status as enum (
    'PENDING',
    'APPROVED',
    'REJECTED',
    'CANCELLED'
  );
exception
  when duplicate_object then null;
end;
$$;

create table public.organization_admin_position_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  requester_user_id uuid not null references public.users(id) on delete restrict,
  requested_role public.app_role not null default 'ADMIN',
  status public.admin_position_request_status not null default 'PENDING',
  requested_at timestamptz not null default now(),
  reviewed_by uuid references public.users(id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organization_admin_position_requests_role_check
    check (requested_role = 'ADMIN'),
  constraint organization_admin_position_requests_review_fields_check
    check (
      (status = 'PENDING' and reviewed_by is null and reviewed_at is null and rejection_reason is null and cancelled_at is null)
      or
      (status = 'APPROVED' and reviewed_by is not null and reviewed_at is not null and rejection_reason is null and cancelled_at is null)
      or
      (status = 'REJECTED' and reviewed_by is not null and reviewed_at is not null and rejection_reason is not null and cancelled_at is null)
      or
      (status = 'CANCELLED' and reviewed_by is null and reviewed_at is null and rejection_reason is null and cancelled_at is not null)
    )
);

create unique index organization_admin_position_requests_pending_key
  on public.organization_admin_position_requests(organization_id, requester_user_id)
  where status = 'PENDING';

create index organization_admin_position_requests_org_status_idx
  on public.organization_admin_position_requests(organization_id, status, requested_at desc);

create index organization_admin_position_requests_requester_idx
  on public.organization_admin_position_requests(requester_user_id, requested_at desc);

alter table public.organization_admin_position_requests enable row level security;

revoke all on table public.organization_admin_position_requests from public, anon, authenticated;
grant select on table public.organization_admin_position_requests to authenticated;

create policy organization_admin_position_requests_select
on public.organization_admin_position_requests
for select
to authenticated
using (
  requester_user_id = (select auth.uid())
  or exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = organization_admin_position_requests.organization_id
      and ou.user_id = (select auth.uid())
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
);

create or replace function public.create_admin_position_request_for_user(
  target_organization_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  actor_role public.app_role;
  request_id uuid;
begin
  if actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if target_organization_id is null then
    raise exception 'Organization is required.';
  end if;

  select ou.role
    into actor_role
  from public.organization_users ou
  where ou.organization_id = target_organization_id
    and ou.user_id = actor_user_id
  for update;

  if not found then
    raise exception 'You must already be an organization member to request an Admin position.';
  end if;

  if actor_role <> 'MEMBER' then
    raise exception 'Only an organization MEMBER can request an Admin position.';
  end if;

  if exists (
    select 1
    from public.organization_admin_position_requests r
    where r.organization_id = target_organization_id
      and r.requester_user_id = actor_user_id
      and r.status = 'PENDING'
  ) then
    raise exception 'You already have a pending Admin position request for this organization.';
  end if;

  insert into public.organization_admin_position_requests (
    organization_id,
    requester_user_id,
    requested_role
  )
  values (
    target_organization_id,
    actor_user_id,
    'ADMIN'
  )
  returning id into request_id;

  insert into public.audit_logs (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    new_data,
    reason
  )
  values (
    target_organization_id,
    actor_user_id,
    'ADMIN_POSITION_REQUEST_CREATED',
    'organization_admin_position_request',
    request_id,
    jsonb_build_object(
      'requester_user_id', actor_user_id,
      'requested_role', 'ADMIN',
      'status', 'PENDING'
    ),
    'Organization Admin position requested by the member.'
  );

  return request_id;
end;
$function$;

create or replace function public.approve_admin_position_request_for_admin(
  target_request_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  request_row public.organization_admin_position_requests%rowtype;
  requester_role public.app_role;
begin
  if actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  select *
    into request_row
  from public.organization_admin_position_requests r
  where r.id = target_request_id
  for update;

  if not found then
    raise exception 'Admin position request not found.';
  end if;

  if request_row.status <> 'PENDING' then
    raise exception 'Only pending Admin position requests can be approved.';
  end if;

  if request_row.requester_user_id = actor_user_id then
    raise exception 'You cannot approve your own Admin position request.';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = request_row.organization_id
      and ou.user_id = actor_user_id
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'Only an organization ADMIN or MAIN_ADMIN can approve this request.';
  end if;

  select ou.role
    into requester_role
  from public.organization_users ou
  where ou.organization_id = request_row.organization_id
    and ou.user_id = request_row.requester_user_id
  for update;

  if not found then
    raise exception 'Requester is no longer an organization member.';
  end if;

  if requester_role <> 'MEMBER' then
    raise exception 'Requester must currently be an organization MEMBER.';
  end if;

  update public.organization_users
  set role = 'ADMIN'
  where organization_id = request_row.organization_id
    and user_id = request_row.requester_user_id;

  update public.organization_admin_position_requests
  set status = 'APPROVED',
      reviewed_by = actor_user_id,
      reviewed_at = now(),
      updated_at = now()
  where id = request_row.id;

  insert into public.audit_logs (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    old_data,
    new_data,
    reason
  )
  values (
    request_row.organization_id,
    actor_user_id,
    'ADMIN_POSITION_REQUEST_APPROVED',
    'organization_admin_position_request',
    request_row.id,
    jsonb_build_object(
      'requester_user_id', request_row.requester_user_id,
      'organization_role', 'MEMBER',
      'status', 'PENDING'
    ),
    jsonb_build_object(
      'requester_user_id', request_row.requester_user_id,
      'organization_role', 'ADMIN',
      'status', 'APPROVED',
      'reviewed_by', actor_user_id
    ),
    'Organization Admin position request approved.'
  );

  return request_row.requester_user_id;
end;
$function$;

create or replace function public.reject_admin_position_request_for_admin(
  target_request_id uuid,
  rejection_reason text
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  request_row public.organization_admin_position_requests%rowtype;
  normalized_reason text := nullif(btrim(rejection_reason), '');
begin
  if actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if normalized_reason is null then
    raise exception 'A rejection reason is required.';
  end if;

  if char_length(normalized_reason) > 1000 then
    raise exception 'Rejection reason is too long.';
  end if;

  select *
    into request_row
  from public.organization_admin_position_requests r
  where r.id = target_request_id
  for update;

  if not found then
    raise exception 'Admin position request not found.';
  end if;

  if request_row.status <> 'PENDING' then
    raise exception 'Only pending Admin position requests can be rejected.';
  end if;

  if request_row.requester_user_id = actor_user_id then
    raise exception 'You cannot reject your own Admin position request.';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = request_row.organization_id
      and ou.user_id = actor_user_id
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'Only an organization ADMIN or MAIN_ADMIN can reject this request.';
  end if;

  update public.organization_admin_position_requests
  set status = 'REJECTED',
      reviewed_by = actor_user_id,
      reviewed_at = now(),
      rejection_reason = normalized_reason,
      updated_at = now()
  where id = request_row.id;

  insert into public.audit_logs (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    old_data,
    new_data,
    reason
  )
  values (
    request_row.organization_id,
    actor_user_id,
    'ADMIN_POSITION_REQUEST_REJECTED',
    'organization_admin_position_request',
    request_row.id,
    jsonb_build_object(
      'requester_user_id', request_row.requester_user_id,
      'status', 'PENDING'
    ),
    jsonb_build_object(
      'requester_user_id', request_row.requester_user_id,
      'status', 'REJECTED',
      'reviewed_by', actor_user_id,
      'rejection_reason', normalized_reason
    ),
    normalized_reason
  );

  return request_row.requester_user_id;
end;
$function$;

create or replace function public.cancel_admin_position_request_for_user(
  target_request_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  request_row public.organization_admin_position_requests%rowtype;
begin
  if actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  select *
    into request_row
  from public.organization_admin_position_requests r
  where r.id = target_request_id
    and r.requester_user_id = actor_user_id
  for update;

  if not found then
    raise exception 'Admin position request not found or not owned by you.';
  end if;

  if request_row.status <> 'PENDING' then
    raise exception 'Only pending Admin position requests can be cancelled.';
  end if;

  update public.organization_admin_position_requests
  set status = 'CANCELLED',
      cancelled_at = now(),
      updated_at = now()
  where id = request_row.id;

  insert into public.audit_logs (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    old_data,
    new_data,
    reason
  )
  values (
    request_row.organization_id,
    actor_user_id,
    'ADMIN_POSITION_REQUEST_CANCELLED',
    'organization_admin_position_request',
    request_row.id,
    jsonb_build_object(
      'requester_user_id', request_row.requester_user_id,
      'status', 'PENDING'
    ),
    jsonb_build_object(
      'requester_user_id', request_row.requester_user_id,
      'status', 'CANCELLED',
      'cancelled_at', now()
    ),
    'Organization Admin position request cancelled by requester.'
  );

  return request_row.id;
end;
$function$;

create or replace function public.emit_organization_notification_event_internal(
  target_organization_id uuid,
  event_type_value text,
  aggregate_type_value text,
  aggregate_id_value uuid,
  payload_value jsonb,
  idempotency_key_value text,
  actor_user_id_value uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_event_id uuid;
  v_actor uuid;
begin
  if not exists (
    select 1
    from public.organizations o
    where o.id = target_organization_id
  ) then
    return null;
  end if;

  v_actor := actor_user_id_value;

  insert into public.notification_events (
    organization_id,
    kuri_id,
    actor_user_id,
    event_type,
    aggregate_type,
    aggregate_id,
    payload,
    idempotency_key
  )
  values (
    target_organization_id,
    null,
    v_actor,
    event_type_value,
    aggregate_type_value,
    aggregate_id_value,
    coalesce(payload_value, '{}'::jsonb),
    idempotency_key_value
  )
  on conflict (organization_id, idempotency_key)
    where idempotency_key is not null
  do nothing
  returning id into v_event_id;

  if v_event_id is null then
    select e.id
      into v_event_id
    from public.notification_events e
    where e.organization_id = target_organization_id
      and e.idempotency_key = idempotency_key_value
    limit 1;
  end if;

  return v_event_id;
end;
$function$;

create or replace function public.emit_admin_position_request_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
begin
  if tg_op = 'INSERT' and new.status = 'PENDING' then
    perform public.emit_organization_notification_event_internal(
      new.organization_id,
      'ADMIN_POSITION_REQUEST',
      'organization_admin_position_request',
      new.id,
      jsonb_build_object(
        'request_id', new.id,
        'organization_id', new.organization_id,
        'requester_user_id', new.requester_user_id,
        'requested_role', new.requested_role::text,
        'status', new.status::text,
        'requested_at', new.requested_at
      ),
      'admin-position-request:' || new.id::text || ':ADMIN_POSITION_REQUEST',
      new.requester_user_id
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_admin_position_request_notification_event
  on public.organization_admin_position_requests;

create trigger emit_admin_position_request_notification_event
after insert on public.organization_admin_position_requests
for each row
execute function public.emit_admin_position_request_notification_event();

revoke all on function public.create_admin_position_request_for_user(uuid)
  from public, anon, authenticated;
grant execute on function public.create_admin_position_request_for_user(uuid)
  to authenticated;

revoke all on function public.approve_admin_position_request_for_admin(uuid)
  from public, anon, authenticated;
grant execute on function public.approve_admin_position_request_for_admin(uuid)
  to authenticated;

revoke all on function public.reject_admin_position_request_for_admin(uuid,text)
  from public, anon, authenticated;
grant execute on function public.reject_admin_position_request_for_admin(uuid,text)
  to authenticated;

revoke all on function public.cancel_admin_position_request_for_user(uuid)
  from public, anon, authenticated;
grant execute on function public.cancel_admin_position_request_for_user(uuid)
  to authenticated;

revoke all on function public.emit_organization_notification_event_internal(uuid,text,text,uuid,jsonb,text,uuid)
  from public, anon, authenticated;

revoke all on function public.emit_admin_position_request_notification_event()
  from public, anon, authenticated;

commit;


begin;

do $$
begin
  create type public.kuri_announcement_status as enum (
    'DRAFT',
    'SCHEDULED',
    'PUBLISHED',
    'WITHDRAWN',
    'EXPIRED'
  );
exception when duplicate_object then null;
end;
$$;

create table public.kuri_announcements (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  author_user_id uuid not null references public.users(id) on delete restrict,
  title text not null,
  body text not null,
  status public.kuri_announcement_status not null default 'DRAFT',
  audience jsonb not null default '{"type":"KURI_FULL_AUDIENCE"}'::jsonb,
  version integer not null default 1,
  scheduled_at timestamptz,
  published_at timestamptz,
  withdrawn_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kuri_announcements_title_check
    check (char_length(btrim(title)) between 1 and 200),
  constraint kuri_announcements_body_check
    check (char_length(btrim(body)) between 1 and 10000),
  constraint kuri_announcements_version_check
    check (version >= 1),
  constraint kuri_announcements_audience_check
    check (
      jsonb_typeof(audience) = 'object'
      and audience->>'type' = 'KURI_FULL_AUDIENCE'
    ),
  constraint kuri_announcements_status_dates_check
    check (
      (status = 'DRAFT' and published_at is null and withdrawn_at is null)
      or
      (status = 'SCHEDULED' and scheduled_at is not null and published_at is null and withdrawn_at is null)
      or
      (status = 'PUBLISHED' and published_at is not null and withdrawn_at is null)
      or
      (status = 'WITHDRAWN' and withdrawn_at is not null)
      or
      (status = 'EXPIRED' and expires_at is not null)
    ),
  constraint kuri_announcements_expiry_check
    check (expires_at is null or scheduled_at is null or expires_at > scheduled_at),
  constraint kuri_announcements_published_expiry_check
    check (expires_at is null or published_at is null or expires_at > published_at)
);

create index kuri_announcements_kuri_status_idx
  on public.kuri_announcements(kuri_id,status,updated_at desc);

create index kuri_announcements_kuri_published_idx
  on public.kuri_announcements(kuri_id,published_at desc)
  where status = 'PUBLISHED';

create index kuri_announcements_scheduled_idx
  on public.kuri_announcements(scheduled_at)
  where status = 'SCHEDULED';

create table public.kuri_announcement_versions (
  id uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.kuri_announcements(id) on delete cascade,
  version integer not null,
  title text not null,
  body text not null,
  audience jsonb not null,
  scheduled_at timestamptz,
  expires_at timestamptz,
  changed_by uuid references public.users(id) on delete set null,
  changed_at timestamptz not null default now(),
  constraint kuri_announcement_versions_unique
    unique (announcement_id,version),
  constraint kuri_announcement_versions_title_check
    check (char_length(btrim(title)) between 1 and 200),
  constraint kuri_announcement_versions_body_check
    check (char_length(btrim(body)) between 1 and 10000),
  constraint kuri_announcement_versions_audience_check
    check (
      jsonb_typeof(audience) = 'object'
      and audience->>'type' = 'KURI_FULL_AUDIENCE'
    )
);

create index kuri_announcement_versions_announcement_idx
  on public.kuri_announcement_versions(announcement_id,version desc);

alter table public.kuri_announcements enable row level security;
alter table public.kuri_announcement_versions enable row level security;

revoke all on table public.kuri_announcements from public,anon,authenticated;
revoke all on table public.kuri_announcement_versions from public,anon,authenticated;

grant select on public.kuri_announcements to authenticated;

create policy kuri_announcements_select
on public.kuri_announcements
for select
to authenticated
using (
  exists (
    select 1
    from public.kuris k
    where k.id = kuri_announcements.kuri_id
      and (
        public.has_kuri_admin_role(
          k.id,
          array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
        )
        or (
          public.is_org_member(k.organization_id)
          and kuri_announcements.status = 'PUBLISHED'
          and (kuri_announcements.expires_at is null or kuri_announcements.expires_at > now())
        )
      )
  )
);

create or replace function public.create_kuri_announcement_for_admin(
  target_kuri_id uuid,
  title_text text,
  body_text text,
  expires_at_value timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  announcement_id uuid;
begin
  if actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to create an announcement for this Kuri.';
  end if;

  if nullif(btrim(title_text),'') is null
     or char_length(btrim(title_text)) > 200
     or nullif(btrim(body_text),'') is null
     or char_length(btrim(body_text)) > 10000 then
    raise exception 'Announcement title/body is invalid.';
  end if;

  if expires_at_value is not null and expires_at_value <= now() then
    raise exception 'Announcement expiry must be in the future.';
  end if;

  insert into public.kuri_announcements(
    kuri_id,author_user_id,title,body,expires_at
  )
  values(
    target_kuri_id,actor_user_id,btrim(title_text),btrim(body_text),expires_at_value
  )
  returning id into announcement_id;

  insert into public.kuri_announcement_versions(
    announcement_id,version,title,body,audience,scheduled_at,expires_at,changed_by
  )
  select id,version,title,body,audience,scheduled_at,expires_at,actor_user_id
  from public.kuri_announcements
  where id=announcement_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_CREATED',
    'kuri_announcement',a.id,
    jsonb_build_object(
      'kuri_id',a.kuri_id,
      'status',a.status::text,
      'version',a.version,
      'title',a.title,
      'expires_at',a.expires_at
    ),
    'Kuri announcement created.'
  from public.kuri_announcements a
  join public.kuris k on k.id=a.kuri_id
  where a.id=announcement_id;

  return announcement_id;
end;
$function$;

create or replace function public.update_kuri_announcement_for_admin(
  target_announcement_id uuid,
  title_text text,
  body_text text,
  expires_at_value timestamptz default null,
  scheduled_at_value timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  a public.kuri_announcements%rowtype;
  next_version integer;
begin
  select *
    into a
  from public.kuri_announcements
  where id=target_announcement_id
  for update;

  if not found then
    raise exception 'Announcement not found.';
  end if;

  if not public.has_kuri_admin_role(
    a.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to edit this announcement.';
  end if;

  if a.status not in ('DRAFT','SCHEDULED') then
    raise exception 'Only draft or scheduled announcements can be edited.';
  end if;

  if nullif(btrim(title_text),'') is null
     or char_length(btrim(title_text)) > 200
     or nullif(btrim(body_text),'') is null
     or char_length(btrim(body_text)) > 10000 then
    raise exception 'Announcement title/body is invalid.';
  end if;

  if scheduled_at_value is not null and scheduled_at_value <= now() then
    raise exception 'Scheduled publication must be in the future.';
  end if;

  if expires_at_value is not null
     and coalesce(scheduled_at_value, a.scheduled_at, now()) >= expires_at_value then
    raise exception 'Announcement expiry must be after publication time.';
  end if;

  next_version := a.version + 1;

  update public.kuri_announcements
  set title=btrim(title_text),
      body=btrim(body_text),
      expires_at=expires_at_value,
      scheduled_at=case
        when scheduled_at_value is null then null
        else scheduled_at_value
      end,
      status=case
        when scheduled_at_value is null then 'DRAFT'::public.kuri_announcement_status
        else 'SCHEDULED'::public.kuri_announcement_status
      end,
      version=next_version,
      updated_at=now()
  where id=a.id;

  insert into public.kuri_announcement_versions(
    announcement_id,version,title,body,audience,scheduled_at,expires_at,changed_by
  )
  values(
    a.id,next_version,btrim(title_text),btrim(body_text),
    a.audience,scheduled_at_value,expires_at_value,actor_user_id
  );

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_EDITED',
    'kuri_announcement',a.id,
    jsonb_build_object(
      'status',a.status::text,
      'version',a.version,
      'title',a.title,
      'body',a.body,
      'scheduled_at',a.scheduled_at,
      'expires_at',a.expires_at
    ),
    jsonb_build_object(
      'status',case when scheduled_at_value is null then 'DRAFT' else 'SCHEDULED' end,
      'version',next_version,
      'title',btrim(title_text),
      'body',btrim(body_text),
      'scheduled_at',scheduled_at_value,
      'expires_at',expires_at_value
    ),
    'Kuri announcement edited.'
  from public.kuris k
  where k.id=a.kuri_id;

  return next_version;
end;
$function$;

create or replace function public.publish_kuri_announcement_for_admin(
  target_announcement_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  a public.kuri_announcements%rowtype;
begin
  select * into a
  from public.kuri_announcements
  where id=target_announcement_id
  for update;

  if not found then
    raise exception 'Announcement not found.';
  end if;

  if not public.has_kuri_admin_role(
    a.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to publish this announcement.';
  end if;

  if a.status not in ('DRAFT','SCHEDULED') then
    raise exception 'Only draft or scheduled announcements can be published.';
  end if;

  if a.expires_at is not null and a.expires_at <= now() then
    raise exception 'Announcement expiry has already passed.';
  end if;

  update public.kuri_announcements
  set status='PUBLISHED',
      scheduled_at=null,
      published_at=coalesce(published_at,now()),
      updated_at=now()
  where id=a.id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_PUBLISHED',
    'kuri_announcement',a.id,
    jsonb_build_object('status',a.status::text,'version',a.version),
    jsonb_build_object('status','PUBLISHED','version',a.version),
    'Kuri announcement published.'
  from public.kuris k
  where k.id=a.kuri_id;

  return a.id;
end;
$function$;

create or replace function public.withdraw_kuri_announcement_for_admin(
  target_announcement_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  a public.kuri_announcements%rowtype;
begin
  select * into a
  from public.kuri_announcements
  where id=target_announcement_id
  for update;

  if not found then
    raise exception 'Announcement not found.';
  end if;

  if not public.has_kuri_admin_role(
    a.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to withdraw this announcement.';
  end if;

  if a.status not in ('PUBLISHED','SCHEDULED') then
    raise exception 'Only published or scheduled announcements can be withdrawn.';
  end if;

  update public.kuri_announcements
  set status='WITHDRAWN',
      withdrawn_at=now(),
      scheduled_at=null,
      updated_at=now()
  where id=a.id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_WITHDRAWN',
    'kuri_announcement',a.id,
    jsonb_build_object('status',a.status::text,'version',a.version),
    jsonb_build_object('status','WITHDRAWN','version',a.version),
    'Kuri announcement withdrawn.'
  from public.kuris k
  where k.id=a.kuri_id;

  return a.id;
end;
$function$;

create or replace function public.process_kuri_announcements()
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_changed integer := 0;
  v_rows integer;
begin
  update public.kuri_announcements
  set status=case
      when expires_at is not null and expires_at <= now()
        then 'EXPIRED'::public.kuri_announcement_status
      else 'PUBLISHED'::public.kuri_announcement_status
    end,
    published_at=case
      when expires_at is not null and expires_at <= now()
        then published_at
      else coalesce(published_at,now())
    end,
    scheduled_at=null,
    updated_at=now()
  where status='SCHEDULED'
    and scheduled_at <= now();
  get diagnostics v_rows=row_count;
  v_changed:=v_changed+v_rows;

  update public.kuri_announcements
  set status='EXPIRED',
      updated_at=now()
  where status='PUBLISHED'
    and expires_at is not null
    and expires_at <= now();
  get diagnostics v_rows=row_count;
  v_changed:=v_changed+v_rows;

  return v_changed;
end;
$function$;

create or replace function public.emit_kuri_announcement_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_org_id uuid;
begin
  if new.status='PUBLISHED'
     and (tg_op='INSERT' or old.status is distinct from new.status) then
    select organization_id into v_org_id
    from public.kuris
    where id=new.kuri_id;

    perform public.emit_notification_event_internal(
      new.kuri_id,
      'KURI_ANNOUNCEMENT',
      'kuri_announcement',
      new.id,
      jsonb_build_object(
        'announcement_id',new.id,
        'kuri_id',new.kuri_id,
        'author_user_id',new.author_user_id,
        'title',new.title,
        'body',new.body,
        'version',new.version,
        'audience',new.audience,
        'published_at',new.published_at,
        'expires_at',new.expires_at
      ),
      'kuri-announcement:'||new.id::text||':published:'||new.version::text,
      new.author_user_id
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_kuri_announcement_notification_event
  on public.kuri_announcements;

create trigger emit_kuri_announcement_notification_event
after insert or update of status on public.kuri_announcements
for each row
execute function public.emit_kuri_announcement_notification_event();

revoke all on function public.create_kuri_announcement_for_admin(uuid,text,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.create_kuri_announcement_for_admin(uuid,text,text,timestamptz)
  to authenticated;

revoke all on function public.update_kuri_announcement_for_admin(uuid,text,text,timestamptz,timestamptz)
  from public,anon,authenticated;
grant execute on function public.update_kuri_announcement_for_admin(uuid,text,text,timestamptz,timestamptz)
  to authenticated;

revoke all on function public.publish_kuri_announcement_for_admin(uuid)
  from public,anon,authenticated;
grant execute on function public.publish_kuri_announcement_for_admin(uuid)
  to authenticated;

revoke all on function public.withdraw_kuri_announcement_for_admin(uuid)
  from public,anon,authenticated;
grant execute on function public.withdraw_kuri_announcement_for_admin(uuid)
  to authenticated;

revoke all on function public.process_kuri_announcements()
  from public,anon,authenticated;

revoke all on function public.emit_kuri_announcement_notification_event()
  from public,anon,authenticated;

select cron.schedule(
  'kuri-announcement-state-processor',
  '* * * * *',
  $$select public.process_kuri_announcements();$$
)
where not exists (
  select 1 from cron.job where jobname='kuri-announcement-state-processor'
);

commit;

begin;

drop policy if exists kuri_announcements_select on public.kuri_announcements;

create policy kuri_announcements_select
on public.kuri_announcements
for select
to authenticated
using (
  exists (
    select 1
    from public.kuris k
    where k.id = kuri_announcements.kuri_id
      and (
        public.has_kuri_admin_role(
          k.id,
          array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
        )
        or exists (
          select 1
          from public.organization_users ou
          where ou.organization_id = k.organization_id
            and ou.user_id = (select auth.uid())
            and ou.role = 'MAIN_ADMIN'::public.app_role
        )
        or (
          kuri_announcements.status = 'PUBLISHED'
          and (kuri_announcements.expires_at is null or kuri_announcements.expires_at > now())
          and exists (
            select 1
            from public.memberships m
            join public.users u on u.person_id = m.person_id
            where m.kuri_id = k.id
              and m.status = 'ACTIVE'::public.membership_status
              and u.id = (select auth.uid())
          )
        )
      )
  )
);

commit;

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
