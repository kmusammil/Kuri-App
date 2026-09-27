begin;

-- NOTIFICATION-001: durable event + notification foundation.
-- Domain workflows will emit events into this outbox and create recipient
-- notifications through the controlled RPCs below. Delivery workers can later
-- consume pending notifications without changing the domain tables.

create table if not exists public.notification_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  kuri_id uuid references public.kuris(id) on delete restrict,
  actor_user_id uuid references public.users(id) on delete restrict,
  event_type text not null,
  aggregate_type text,
  aggregate_id uuid,
  payload jsonb not null default '{}'::jsonb,
  idempotency_key text,
  created_at timestamptz not null default now(),
  constraint notification_events_type_check check (
    event_type in (
      'KURI_START_REMINDER',
      'KURI_END_DATE_REMINDER',
      'ENROLLMENT_REMINDER',
      'CYCLE_REMINDER',
      'PAYMENT_REMINDER',
      'LATE_PAYMENT_ALERT',
      'LATE_FEE_ACTIVATED',
      'LATE_FEE_CHANGED',
      'DRAW_PREPARATION',
      'DRAW_RESULT',
      'WINNER_NOTIFICATION',
      'PAYOUT_NOTIFICATION',
      'EXIT_REQUEST',
      'EXIT_APPROVAL',
      'EXIT_SETTLEMENT',
      'DEATH_VERIFICATION',
      'SUCCESSION',
      'ADMIN_SECURITY'
    )
  ),
  constraint notification_events_payload_object_check check (jsonb_typeof(payload) = 'object')
);

create index if not exists notification_events_org_created_idx
  on public.notification_events(organization_id, created_at desc);

create index if not exists notification_events_kuri_created_idx
  on public.notification_events(kuri_id, created_at desc);

create index if not exists notification_events_type_created_idx
  on public.notification_events(event_type, created_at desc);

create unique index if not exists notification_events_idempotency_uniq
  on public.notification_events(organization_id, idempotency_key)
  where idempotency_key is not null;

alter table public.notification_events enable row level security;
revoke all on table public.notification_events from public, anon, authenticated;

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.notification_events(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  recipient_user_id uuid not null references public.users(id) on delete restrict,
  channel text not null default 'IN_APP',
  status text not null default 'PENDING',
  title text not null,
  body text not null,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  failed_at timestamptz,
  read_at timestamptz,
  attempt_count integer not null default 0,
  last_error text,
  constraint notifications_channel_check check (channel in ('IN_APP','EMAIL','SMS','PUSH')),
  constraint notifications_status_check check (status in ('PENDING','PROCESSING','SENT','FAILED','READ')),
  constraint notifications_attempt_count_check check (attempt_count >= 0),
  constraint notifications_data_object_check check (jsonb_typeof(data) = 'object')
);

create index if not exists notifications_recipient_status_idx
  on public.notifications(recipient_user_id, status, created_at desc);

create index if not exists notifications_org_created_idx
  on public.notifications(organization_id, created_at desc);

create index if not exists notifications_event_idx
  on public.notifications(event_id);

create unique index if not exists notifications_event_recipient_channel_uniq
  on public.notifications(event_id, recipient_user_id, channel);

alter table public.notifications enable row level security;

revoke all on table public.notifications from public, anon;
grant select on table public.notifications to authenticated;

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own
on public.notifications
for select
to authenticated
using (recipient_user_id = auth.uid());

-- Events are write/read controlled through SECURITY DEFINER functions. The
-- notification table is directly readable only by its recipient; mutations
-- remain function-only.

create or replace function public.record_notification_event_for_admin(
  target_kuri_id uuid,
  event_type_value text,
  aggregate_type_value text default null,
  aggregate_id_value uuid default null,
  payload_value jsonb default '{}'::jsonb,
  idempotency_key_value text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_actor uuid := auth.uid();
  v_org_id uuid;
  v_event_id uuid;
begin
  if v_actor is null then
    raise exception 'You must be signed in.';
  end if;

  if target_kuri_id is null then
    raise exception 'Kuri is required.';
  end if;

  if event_type_value is null or event_type_value not in (
    'KURI_START_REMINDER',
    'KURI_END_DATE_REMINDER',
    'ENROLLMENT_REMINDER',
    'CYCLE_REMINDER',
    'PAYMENT_REMINDER',
    'LATE_PAYMENT_ALERT',
    'LATE_FEE_ACTIVATED',
    'LATE_FEE_CHANGED',
    'DRAW_PREPARATION',
    'DRAW_RESULT',
    'WINNER_NOTIFICATION',
    'PAYOUT_NOTIFICATION',
    'EXIT_REQUEST',
    'EXIT_APPROVAL',
    'EXIT_SETTLEMENT',
    'DEATH_VERIFICATION',
    'SUCCESSION',
    'ADMIN_SECURITY'
  ) then
    raise exception 'Unsupported notification event type.';
  end if;

  if payload_value is null or jsonb_typeof(payload_value) <> 'object' then
    raise exception 'Notification event payload must be a JSON object.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to create notification events for this Kuri.';
  end if;

  select k.organization_id
    into v_org_id
  from public.kuris k
  where k.id = target_kuri_id;

  if v_org_id is null then
    raise exception 'Kuri not found.';
  end if;

  if idempotency_key_value is not null then
    select e.id
      into v_event_id
    from public.notification_events e
    where e.organization_id = v_org_id
      and e.idempotency_key = idempotency_key_value
    limit 1;

    if v_event_id is not null then
      return v_event_id;
    end if;
  end if;

  insert into public.notification_events(
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
    v_org_id,
    target_kuri_id,
    v_actor,
    event_type_value,
    aggregate_type_value,
    aggregate_id_value,
    payload_value,
    idempotency_key_value
  )
  returning id into v_event_id;

  return v_event_id;
exception
  when unique_violation then
    if idempotency_key_value is not null then
      select e.id
        into v_event_id
      from public.notification_events e
      where e.organization_id = v_org_id
        and e.idempotency_key = idempotency_key_value
      limit 1;

      if v_event_id is not null then
        return v_event_id;
      end if;
    end if;
    raise;
end;
$function$;

revoke all on function public.record_notification_event_for_admin(uuid,text,text,uuid,jsonb,text)
  from public, anon;
grant execute on function public.record_notification_event_for_admin(uuid,text,text,uuid,jsonb,text)
  to authenticated;

create or replace function public.create_notification_for_admin(
  target_event_id uuid,
  target_user_id uuid,
  title_value text,
  body_value text,
  channel_value text default 'IN_APP',
  data_value jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_actor uuid := auth.uid();
  v_event public.notification_events%rowtype;
  v_notification_id uuid;
begin
  if v_actor is null then
    raise exception 'You must be signed in.';
  end if;

  if target_event_id is null or target_user_id is null then
    raise exception 'Event and recipient are required.';
  end if;

  if title_value is null or char_length(btrim(title_value)) = 0 then
    raise exception 'Notification title is required.';
  end if;

  if body_value is null or char_length(btrim(body_value)) = 0 then
    raise exception 'Notification body is required.';
  end if;

  if channel_value is null or channel_value not in ('IN_APP','EMAIL','SMS','PUSH') then
    raise exception 'Unsupported notification channel.';
  end if;

  if data_value is null or jsonb_typeof(data_value) <> 'object' then
    raise exception 'Notification data must be a JSON object.';
  end if;

  select *
    into v_event
  from public.notification_events e
  where e.id = target_event_id;

  if v_event.id is null then
    raise exception 'Notification event not found.';
  end if;

  if not public.has_kuri_admin_role(
    v_event.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to create notifications for this event.';
  end if;

  if not exists (
    select 1
    from public.users u
    where u.id = target_user_id
  ) then
    raise exception 'Notification recipient not found.';
  end if;

  insert into public.notifications(
    event_id,
    organization_id,
    recipient_user_id,
    channel,
    status,
    title,
    body,
    data
  )
  values (
    target_event_id,
    v_event.organization_id,
    target_user_id,
    channel_value,
    'PENDING',
    btrim(title_value),
    body_value,
    data_value
  )
  on conflict (event_id, recipient_user_id, channel)
  do update set
    title = excluded.title,
    body = excluded.body,
    data = excluded.data
  returning id into v_notification_id;

  return v_notification_id;
end;
$function$;

revoke all on function public.create_notification_for_admin(uuid,uuid,text,text,text,jsonb)
  from public, anon;
grant execute on function public.create_notification_for_admin(uuid,uuid,text,text,text,jsonb)
  to authenticated;

create or replace function public.mark_notification_read(target_notification_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $function$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  update public.notifications
  set status = 'READ',
      read_at = coalesce(read_at, now())
  where id = target_notification_id
    and recipient_user_id = auth.uid();

  if not found then
    raise exception 'Notification not found.';
  end if;
end;
$function$;

revoke all on function public.mark_notification_read(uuid) from public, anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;

create or replace function public.list_my_notifications(
  limit_value integer default 50,
  offset_value integer default 0
)
returns table(
  id uuid,
  event_id uuid,
  event_type text,
  channel text,
  status text,
  title text,
  body text,
  data jsonb,
  created_at timestamptz,
  sent_at timestamptz,
  read_at timestamptz
)
language sql
stable
security definer
set search_path=public
as $function$
  select
    n.id,
    n.event_id,
    e.event_type,
    n.channel,
    n.status,
    n.title,
    n.body,
    n.data,
    n.created_at,
    n.sent_at,
    n.read_at
  from public.notifications n
  join public.notification_events e on e.id = n.event_id
  where n.recipient_user_id = auth.uid()
  order by n.created_at desc
  limit greatest(1, least(coalesce(limit_value,50),100))
  offset greatest(coalesce(offset_value,0),0);
$function$;

revoke all on function public.list_my_notifications(integer,integer) from public, anon;
grant execute on function public.list_my_notifications(integer,integer) to authenticated;

create or replace function public.claim_pending_notification_for_delivery(
  target_notification_id uuid
)
returns table(
  notification_id uuid,
  event_id uuid,
  recipient_user_id uuid,
  channel text,
  title text,
  body text,
  data jsonb,
  attempt_count integer
)
language plpgsql
security definer
set search_path=public
as $function$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  return query
  update public.notifications n
  set status = 'PROCESSING',
      attempt_count = n.attempt_count + 1
  where n.id = target_notification_id
    and n.status = 'PENDING'
  returning
    n.id,
    n.event_id,
    n.recipient_user_id,
    n.channel,
    n.title,
    n.body,
    n.data,
    n.attempt_count;
end;
$function$;

revoke all on function public.claim_pending_notification_for_delivery(uuid)
  from public, anon, authenticated;

create or replace function public.complete_notification_delivery(
  target_notification_id uuid,
  delivery_succeeded boolean,
  error_message text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $function$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if delivery_succeeded then
    update public.notifications
    set status='SENT',
        sent_at=coalesce(sent_at,now()),
        failed_at=null,
        last_error=null
    where id=target_notification_id
      and status='PROCESSING';
  else
    update public.notifications
    set status='FAILED',
        failed_at=now(),
        last_error=nullif(btrim(coalesce(error_message,'')),'')
    where id=target_notification_id
      and status='PROCESSING';
  end if;

  if not found then
    raise exception 'Notification is not in PROCESSING state.';
  end if;
end;
$function$;

revoke all on function public.complete_notification_delivery(uuid,boolean,text)
  from public, anon, authenticated;

commit;