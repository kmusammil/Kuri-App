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