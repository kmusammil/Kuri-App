-- Domain reconciliation batch: Person Claim + Notification Producers/Scheduler.
-- Source migrations from main:
--   20260927113000_person_claim_workflow_v1.sql
--   20260927160000_notification_domain_producers_v1.sql
--   20260927170000_notification_scheduled_producer_v1.sql
-- Person-claim authorization is adapted to the branch's explicit organization_users model.

begin;

create table if not exists public.person_claim_tokens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  issued_by_user_id uuid not null references public.users(id) on delete restrict,
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by_user_id uuid references public.users(id) on delete restrict,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > created_at)
);

create index if not exists person_claim_tokens_person_idx
  on public.person_claim_tokens(person_id, created_at desc);

create index if not exists person_claim_tokens_active_idx
  on public.person_claim_tokens(person_id, expires_at)
  where used_at is null and revoked_at is null;

alter table public.person_claim_tokens enable row level security;

revoke all on table public.person_claim_tokens from public, anon, authenticated;

create unique index if not exists users_person_id_unique
  on public.users(person_id)
  where person_id is not null;

create or replace function public.create_person_claim_token_for_admin(
  target_person_id uuid,
  expires_in_hours integer default 72
)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_org_id uuid;
  v_token text;
  v_hash text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required.';
  end if;

  if expires_in_hours < 1 or expires_in_hours > 168 then
    raise exception 'Claim token expiry must be between 1 and 168 hours.';
  end if;

  select p.organization_id
    into v_org_id
  from public.people p
  where p.id = target_person_id
  for update;

  if v_org_id is null then
    raise exception 'Person not found.';
  end if;

  if not exists (select 1 from public.organization_users ou where ou.organization_id=v_org_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])) then
    raise exception 'You do not have permission to issue a claim token for this person.';
  end if;

  if exists (
    select 1
    from public.users u
    where u.person_id = target_person_id
  ) then
    raise exception 'This person is already linked to a user account.';
  end if;

  v_token :=
    lower(encode(gen_random_bytes(24), 'hex'));

  v_hash :=
    encode(digest(v_token, 'sha256'), 'hex');

  insert into public.person_claim_tokens (
    organization_id,
    person_id,
    issued_by_user_id,
    token_hash,
    expires_at
  )
  values (
    v_org_id,
    target_person_id,
    auth.uid(),
    v_hash,
    now() + make_interval(hours => expires_in_hours)
  );

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
    v_org_id,
    auth.uid(),
    'person_claim_token_created',
    'person',
    target_person_id,
    jsonb_build_object(
      'expires_in_hours', expires_in_hours
    ),
    'Issued one-time person claim token'
  );

  return v_token;
end;
$function$;

create or replace function public.claim_existing_person(
  claim_token text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_token_id uuid;
  v_person_id uuid;
  v_org_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required.';
  end if;

  claim_token := lower(trim(claim_token));

  if length(claim_token) <> 48
     or claim_token !~ '^[0-9a-f]{48}$' then
    raise exception 'Invalid claim token.';
  end if;

  select u.person_id
    into v_person_id
  from public.users u
  where u.id = v_user_id
  for update;

  if not found then
    raise exception 'User account not found.';
  end if;

  if v_person_id is not null then
    raise exception 'This user account is already linked to a person.';
  end if;

  select
    pct.id,
    pct.person_id,
    pct.organization_id
    into v_token_id, v_person_id, v_org_id
  from public.person_claim_tokens pct
  where pct.token_hash = encode(digest(claim_token, 'sha256'), 'hex')
    and pct.used_at is null
    and pct.revoked_at is null
    and pct.expires_at > now()
  for update;

  if not found then
    raise exception 'Invalid, expired, revoked, or already-used claim token.';
  end if;

  if exists (
    select 1
    from public.users u
    where u.person_id = v_person_id
      and u.id <> v_user_id
  ) then
    raise exception 'This person is already linked to another user account.';
  end if;

  update public.users
  set person_id = v_person_id
  where id = v_user_id
    and person_id is null;

  if not found then
    raise exception 'Unable to claim this person.';
  end if;

  update public.person_claim_tokens
  set used_at = now(),
      used_by_user_id = v_user_id
  where id = v_token_id
    and used_at is null
    and revoked_at is null;

  if not found then
    raise exception 'Claim token was already consumed.';
  end if;

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
    v_org_id,
    v_user_id,
    'person_claimed',
    'person',
    v_person_id,
    jsonb_build_object(
      'claim_token_id', v_token_id
    ),
    'Authenticated user claimed existing person identity'
  );

  return v_person_id;
end;
$function$;

revoke all on function public.create_person_claim_token_for_admin(uuid, integer) from public, anon;
grant execute on function public.create_person_claim_token_for_admin(uuid, integer) to authenticated;

revoke all on function public.claim_existing_person(text) from public, anon;
grant execute on function public.claim_existing_person(text) to authenticated;

commit;

begin;

-- Notification producer completion checkpoint:
-- Wire currently existing domain tables to the event catalog.
-- This checkpoint does not create scheduled reminder generation or an
-- admin-position request table because those are separate domain features.

create or replace function public.emit_join_request_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_actor uuid;
  v_org_id uuid;
begin
  select k.organization_id into v_org_id
  from public.kuris k
  where k.id=new.kuri_id;

  v_actor:=coalesce(new.applicant_user_id,auth.uid());

  if tg_op='INSERT' and new.status::text='PENDING' then
    perform public.emit_notification_event_internal(
      new.kuri_id,
      'JOIN_REQUEST',
      'kuri_join_request',
      new.id,
      jsonb_build_object(
        'join_request_id',new.id,
        'kuri_id',new.kuri_id,
        'applicant_user_id',new.applicant_user_id,
        'applicant_person_id',new.applicant_person_id,
        'status',new.status::text,
        'requested_at',new.requested_at
      ),
      'join-request:'||new.id::text||':JOIN_REQUEST',
      v_actor
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_join_request_notification_event on public.kuri_join_requests;
create trigger emit_join_request_notification_event
after insert on public.kuri_join_requests
for each row execute function public.emit_join_request_notification_event();

revoke all on function public.emit_join_request_notification_event()
  from public,anon,authenticated;


create or replace function public.emit_invitation_response_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
begin
  -- The invitation state machine has no DECLINED state; CONSUMED is the
  -- durable acceptance/response point.
  if tg_op='UPDATE'
     and old.status::text='PENDING'
     and new.status::text='CONSUMED' then
    perform public.emit_notification_event_internal(
      new.kuri_id,
      'INVITATION_RESPONSE',
      'kuri_invitation',
      new.id,
      jsonb_build_object(
        'invitation_id',new.id,
        'kuri_id',new.kuri_id,
        'recipient_user_id',new.recipient_user_id,
        'recipient_email',new.recipient_email,
        'recipient_phone',new.recipient_phone,
        'status',new.status::text,
        'consumed_at',new.consumed_at,
        'consumed_by',new.consumed_by
      ),
      'invitation:'||new.id::text||':INVITATION_RESPONSE:CONSUMED',
      coalesce(new.consumed_by,auth.uid())
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_invitation_response_notification_event on public.kuri_invitations;
create trigger emit_invitation_response_notification_event
after update of status on public.kuri_invitations
for each row execute function public.emit_invitation_response_notification_event();

revoke all on function public.emit_invitation_response_notification_event()
  from public,anon,authenticated;


create or replace function public.emit_kuri_schedule_changed_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_kuri_id uuid;
  v_actor uuid;
  v_payload jsonb;
  v_key text;
begin
  if tg_table_name='cycle_schedule_overrides' then
    v_kuri_id:=new.kuri_id;
    v_actor:=new.changed_by;
    v_payload:=jsonb_build_object(
      'schedule_source','cycle_schedule_override',
      'override_id',new.id,
      'cycle_id',new.cycle_id,
      'previous_period_start',new.previous_period_start,
      'previous_period_end',new.previous_period_end,
      'previous_due_date',new.previous_due_date,
      'previous_draw_date',new.previous_draw_date,
      'new_period_start',new.new_period_start,
      'new_period_end',new.new_period_end,
      'new_due_date',new.new_due_date,
      'new_draw_date',new.new_draw_date,
      'reason',new.reason
    );
    v_key:='schedule-override:'||new.id::text||':KURI_SCHEDULE_CHANGED';
  elsif tg_table_name='kuri_custom_cycle_schedules' then
    v_kuri_id:=new.kuri_id;
    v_actor:=auth.uid();
    v_payload:=jsonb_build_object(
      'schedule_source','custom_cycle_schedule',
      'schedule_id',new.id,
      'cycle_number',new.cycle_number,
      'period_start',new.period_start,
      'period_end',new.period_end,
      'due_date',new.due_date,
      'draw_date',new.draw_date
    );
    v_key:='custom-schedule:'||new.id::text||':KURI_SCHEDULE_CHANGED:'||coalesce(new.updated_at::text,new.created_at::text);
  else
    v_kuri_id:=new.id;
    v_actor:=auth.uid();
    v_payload:=jsonb_build_object(
      'schedule_source','kuri',
      'kuri_id',new.id,
      'previous_start_date',old.start_date,
      'new_start_date',new.start_date,
      'previous_frequency',old.frequency::text,
      'new_frequency',new.frequency::text,
      'previous_due_day',old.due_day,
      'new_due_day',new.due_day,
      'previous_draw_day',old.draw_day,
      'new_draw_day',new.draw_day,
      'previous_number_of_cycles',old.number_of_cycles,
      'new_number_of_cycles',new.number_of_cycles,
      'previous_schedule_mode',old.schedule_mode::text,
      'new_schedule_mode',new.schedule_mode::text
    );
    v_key:='kuri-schedule:'||new.id::text||':KURI_SCHEDULE_CHANGED:'||new.updated_at::text;
  end if;

  perform public.emit_notification_event_internal(
    v_kuri_id,
    'KURI_SCHEDULE_CHANGED',
    'kuri_schedule',
    v_kuri_id,
    v_payload,
    v_key,
    v_actor
  );

  return new;
end;
$function$;

drop trigger if exists emit_cycle_schedule_override_notification on public.cycle_schedule_overrides;
create trigger emit_cycle_schedule_override_notification
after insert on public.cycle_schedule_overrides
for each row execute function public.emit_kuri_schedule_changed_notification_event();

drop trigger if exists emit_custom_cycle_schedule_notification on public.kuri_custom_cycle_schedules;
create trigger emit_custom_cycle_schedule_notification
after insert or update on public.kuri_custom_cycle_schedules
for each row execute function public.emit_kuri_schedule_changed_notification_event();

drop trigger if exists emit_kuri_schedule_changed_notification on public.kuris;
create trigger emit_kuri_schedule_changed_notification
after update of start_date,frequency,due_day,draw_day,number_of_cycles,schedule_mode on public.kuris
for each row
when (
  old.start_date is distinct from new.start_date
  or old.frequency is distinct from new.frequency
  or old.due_day is distinct from new.due_day
  or old.draw_day is distinct from new.draw_day
  or old.number_of_cycles is distinct from new.number_of_cycles
  or old.schedule_mode is distinct from new.schedule_mode
)
execute function public.emit_kuri_schedule_changed_notification_event();

revoke all on function public.emit_kuri_schedule_changed_notification_event()
  from public,anon,authenticated;


create or replace function public.emit_death_report_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_kuri_id uuid;
begin
  if tg_op='INSERT' and new.reason::text='DEATH' then
    select m.kuri_id into v_kuri_id
    from public.memberships m
    where m.id=new.membership_id;

    perform public.emit_notification_event_internal(
      v_kuri_id,
      'DEATH_REPORT',
      'membership_exit',
      new.id,
      jsonb_build_object(
        'exit_id',new.id,
        'membership_id',new.membership_id,
        'reason',new.reason::text,
        'death_date',new.death_date,
        'status',new.status::text,
        'requested_at',new.requested_at
      ),
      'exit:'||new.id::text||':DEATH_REPORT',
      auth.uid()
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_death_report_notification_event on public.membership_exits;
create trigger emit_death_report_notification_event
after insert on public.membership_exits
for each row execute function public.emit_death_report_notification_event();

revoke all on function public.emit_death_report_notification_event()
  from public,anon,authenticated;

commit;

begin;

-- NOTIFICATION-001 scheduled reminder producer v1.
-- Generates date-driven notification events; delivery remains handled by
-- the existing policy-driven dispatcher.
--
-- Business dates are evaluated in the application's current operating
-- timezone (India Standard Time). This avoids firing a "today" reminder
-- against the previous UTC calendar date.

create or replace function public.generate_scheduled_notification_events(
  run_date date default (now() at time zone 'Asia/Kolkata')::date
)
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_inserted integer := 0;
  v_rows integer;
begin
  if run_date is null then
    raise exception 'run_date must not be null';
  end if;

  -- Kuri start reminder.
  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  select
    k.organization_id,
    k.id,
    k.created_by,
    'KURI_START_REMINDER',
    'kuri',
    k.id,
    jsonb_build_object(
      'kuri_id',k.id,
      'kuri_name',k.name,
      'start_date',k.start_date,
      'reminder_date',run_date,
      'days_before',p.offset_days
    ),
    'scheduled:kuri:'||k.id::text||':KURI_START_REMINDER:'||k.start_date::text||':'||p.offset_days::text
  from public.kuris k
  cross join lateral (
    select unnest(nep.reminder_offsets_days) as offset_days
    from public.notification_event_policies nep
    where nep.event_type='KURI_START_REMINDER'
      and nep.enabled
  ) p
  where k.start_date = run_date + p.offset_days
    and k.start_date >= run_date
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_inserted + v_rows;

  -- Kuri end-date reminder. The Kuri end date is the final cycle period_end.
  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  select
    k.organization_id,
    k.id,
    k.created_by,
    'KURI_END_DATE_REMINDER',
    'kuri',
    k.id,
    jsonb_build_object(
      'kuri_id',k.id,
      'kuri_name',k.name,
      'end_date',x.end_date,
      'reminder_date',run_date,
      'days_before',p.offset_days
    ),
    'scheduled:kuri:'||k.id::text||':KURI_END_DATE_REMINDER:'||x.end_date::text||':'||p.offset_days::text
  from public.kuris k
  join lateral (
    select max(c.period_end) as end_date
    from public.cycles c
    where c.kuri_id=k.id
  ) x on x.end_date is not null
  cross join lateral (
    select unnest(nep.reminder_offsets_days) as offset_days
    from public.notification_event_policies nep
    where nep.event_type='KURI_END_DATE_REMINDER'
      and nep.enabled
  ) p
  where x.end_date = run_date + p.offset_days
    and x.end_date >= run_date
    and k.status::text not in ('COMPLETED','ARCHIVED')
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_inserted + v_rows;

  -- Enrollment reminder: enrollment is considered relevant while the Kuri
  -- has not been closed and its start date has not passed.
  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  select
    k.organization_id,
    k.id,
    k.created_by,
    'ENROLLMENT_REMINDER',
    'kuri',
    k.id,
    jsonb_build_object(
      'kuri_id',k.id,
      'kuri_name',k.name,
      'start_date',k.start_date,
      'reminder_date',run_date,
      'days_before',p.offset_days
    ),
    'scheduled:kuri:'||k.id::text||':ENROLLMENT_REMINDER:'||k.start_date::text||':'||p.offset_days::text
  from public.kuris k
  cross join lateral (
    select unnest(nep.reminder_offsets_days) as offset_days
    from public.notification_event_policies nep
    where nep.event_type='ENROLLMENT_REMINDER'
      and nep.enabled
  ) p
  where k.start_date = run_date + p.offset_days
    and k.start_date >= run_date
    and (k.enrollment_closed_at is null or k.enrollment_closed_at::date > run_date)
    and k.status::text not in ('COMPLETED','ARCHIVED')
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_inserted + v_rows;

  -- Cycle reminder: one reminder opportunity per configured offset and cycle.
  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  select
    k.organization_id,
    c.kuri_id,
    k.created_by,
    'CYCLE_REMINDER',
    'cycle',
    c.id,
    jsonb_build_object(
      'cycle_id',c.id,
      'cycle_number',c.cycle_number,
      'due_date',c.due_date,
      'reminder_date',run_date,
      'days_before',p.offset_days
    ),
    'scheduled:cycle:'||c.id::text||':CYCLE_REMINDER:'||c.due_date::text||':'||p.offset_days::text
  from public.cycles c
  join public.kuris k on k.id=c.kuri_id
  cross join lateral (
    select unnest(nep.reminder_offsets_days) as offset_days
    from public.notification_event_policies nep
    where nep.event_type='CYCLE_REMINDER'
      and nep.enabled
  ) p
  where c.due_date = run_date + p.offset_days
    and c.due_date >= run_date
    and c.status::text not in ('COMPLETED','CANCELLED')
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_inserted + v_rows;

  -- Payment reminders: only installments that remain outstanding.
  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  select
    k.organization_id,
    k.id,
    k.created_by,
    'PAYMENT_REMINDER',
    'installment',
    i.id,
    jsonb_build_object(
      'installment_id',i.id,
      'membership_id',i.membership_id,
      'cycle_id',i.cycle_id,
      'amount_due',i.amount_due,
      'amount_paid',i.amount_paid,
      'due_date',i.due_date,
      'reminder_date',run_date,
      'days_before',p.offset_days
    ),
    'scheduled:installment:'||i.id::text||':PAYMENT_REMINDER:'||i.due_date::text||':'||p.offset_days::text
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.kuris k on k.id=m.kuri_id
  cross join lateral (
    select unnest(nep.reminder_offsets_days) as offset_days
    from public.notification_event_policies nep
    where nep.event_type='PAYMENT_REMINDER'
      and nep.enabled
  ) p
  where i.due_date = run_date + p.offset_days
    and i.due_date >= run_date
    and coalesce(i.amount_paid,0) < i.amount_due
    and m.status::text in ('ACTIVE','PENDING')
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_inserted + v_rows;

  -- Late-payment alert: only after the due date and only while unpaid.
  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  select
    k.organization_id,
    k.id,
    k.created_by,
    'LATE_PAYMENT_ALERT',
    'installment',
    i.id,
    jsonb_build_object(
      'installment_id',i.id,
      'membership_id',i.membership_id,
      'cycle_id',i.cycle_id,
      'amount_due',i.amount_due,
      'amount_paid',i.amount_paid,
      'due_date',i.due_date,
      'alert_date',run_date,
      'days_after_due',p.offset_days
    ),
    'scheduled:installment:'||i.id::text||':LATE_PAYMENT_ALERT:'||i.due_date::text||':'||p.offset_days::text
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.kuris k on k.id=m.kuri_id
  cross join lateral (
    select unnest(nep.reminder_offsets_days) as offset_days
    from public.notification_event_policies nep
    where nep.event_type='LATE_PAYMENT_ALERT'
      and nep.enabled
  ) p
  where i.due_date = run_date - p.offset_days
    and i.due_date < run_date
    and coalesce(i.amount_paid,0) < i.amount_due
    and m.status::text in ('ACTIVE','PENDING')
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_inserted + v_rows;

  -- Draw preparation reminder. If the cycle has already reached
  -- DRAW_PENDING, the domain trigger has already recorded preparation;
  -- do not create a stale duplicate reminder.
  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  select
    k.organization_id,
    c.kuri_id,
    k.created_by,
    'DRAW_PREPARATION',
    'cycle',
    c.id,
    jsonb_build_object(
      'cycle_id',c.id,
      'cycle_number',c.cycle_number,
      'draw_date',c.draw_date,
      'reminder_date',run_date,
      'days_before',p.offset_days,
      'source','SCHEDULED_REMINDER'
    ),
    'scheduled:cycle:'||c.id::text||':DRAW_PREPARATION:'||c.draw_date::text||':'||p.offset_days::text
  from public.cycles c
  join public.kuris k on k.id=c.kuri_id
  cross join lateral (
    select unnest(nep.reminder_offsets_days) as offset_days
    from public.notification_event_policies nep
    where nep.event_type='DRAW_PREPARATION'
      and nep.enabled
  ) p
  where c.draw_date = run_date + p.offset_days
    and c.draw_date >= run_date
    and c.status::text not in ('DRAW_PENDING','COMPLETED','CANCELLED')
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null do nothing;
  get diagnostics v_rows = row_count;
  v_inserted := v_inserted + v_rows;

  return v_inserted;
end;
$function$;

revoke all on function public.generate_scheduled_notification_events(date)
  from public,anon,authenticated;

-- Run once per day after midnight IST (18:30 UTC).
select cron.schedule(
  'kuri-notification-scheduled-producer',
  '30 18 * * *',
  $$select public.generate_scheduled_notification_events();$$
)
where not exists (
  select 1 from cron.job
  where jobname='kuri-notification-scheduled-producer'
);

commit;
