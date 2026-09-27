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
