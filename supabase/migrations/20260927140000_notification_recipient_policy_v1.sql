-- Notification recipient policy and event catalog v1
-- Defines notification audience/scope semantics without coupling domain actions
-- to a particular delivery channel. Existing delivery remains IN_APP-first.

alter table public.notification_events
  drop constraint if exists notification_events_type_check;

alter table public.notification_events
  add constraint notification_events_type_check
  check (
    event_type = any (
      array[
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
        'DEATH_REPORT',
        'DEATH_VERIFICATION',
        'SUCCESSION',
        'ADMIN_POSITION_REQUEST',
        'JOIN_REQUEST',
        'INVITATION_RESPONSE',
        'KURI_SCHEDULE_CHANGED',
        'KURI_ANNOUNCEMENT',
        'ADMIN_SECURITY'
      ]::text[]
    )
  );

create table if not exists public.notification_event_policies (
  event_type text primary key,
  category text not null,
  timing_kind text not null,
  reminder_offsets_days integer[] not null default '{}'::integer[],
  actor_policy text not null default 'EXCLUDE'
    check (actor_policy in ('EXCLUDE', 'INCLUDE', 'EVENT_SPECIFIC')),
  no_user_policy text not null default 'NO_APP_NOTIFICATION'
    check (no_user_policy in ('NO_APP_NOTIFICATION', 'INVITATION_CLAIM', 'EVENT_SPECIFIC')),
  recipient_rules jsonb not null,
  default_channels text[] not null default array['IN_APP']::text[],
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notification_event_policies_category_check
    check (category in ('REMINDER', 'REQUEST', 'RESULT', 'FINANCIAL', 'LIFECYCLE', 'SECURITY', 'BROADCAST')),
  constraint notification_event_policies_timing_check
    check (timing_kind in ('IMMEDIATE', 'SCHEDULED', 'CONFIRMATION', 'BROADCAST')),
  constraint notification_event_policies_offsets_check
    check (
      (timing_kind <> 'SCHEDULED' and cardinality(reminder_offsets_days) = 0)
      or
      (timing_kind = 'SCHEDULED' and cardinality(reminder_offsets_days) > 0)
    ),
  constraint notification_event_policies_rules_object_check
    check (jsonb_typeof(recipient_rules) = 'object'),
  constraint notification_event_policies_channels_check
    check (
      default_channels <@ array['IN_APP','PUSH','EMAIL','SMS']::text[]
      and cardinality(default_channels) > 0
    )
);

alter table public.notification_event_policies enable row level security;

revoke all on table public.notification_event_policies from anon, authenticated;

insert into public.notification_event_policies
  (event_type, category, timing_kind, reminder_offsets_days, actor_policy, no_user_policy, recipient_rules)
values
  ('KURI_START_REMINDER', 'REMINDER', 'SCHEDULED', array[1], 'INCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('KURI_END_DATE_REMINDER', 'REMINDER', 'SCHEDULED', array[7,1], 'INCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('ENROLLMENT_REMINDER', 'REMINDER', 'SCHEDULED', array[3], 'INCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('CYCLE_REMINDER', 'REMINDER', 'SCHEDULED', array[1], 'INCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('PAYMENT_REMINDER', 'REMINDER', 'SCHEDULED', array[3,0], 'INCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"KURI_MEMBER","scope":"MEMBERSHIP_WITH_OUTSTANDING_INSTALLMENT"}]}'::jsonb),
  ('LATE_PAYMENT_ALERT', 'FINANCIAL', 'IMMEDIATE', array[]::integer[], 'INCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"MEMBERSHIP_WITH_UNPAID_INSTALLMENT"}]}'::jsonb),
  ('LATE_FEE_ACTIVATED', 'FINANCIAL', 'IMMEDIATE', array[]::integer[], 'INCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('LATE_FEE_CHANGED', 'FINANCIAL', 'IMMEDIATE', array[]::integer[], 'INCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('DRAW_PREPARATION', 'REMINDER', 'SCHEDULED', array[1], 'INCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('DRAW_RESULT', 'RESULT', 'IMMEDIATE', array[]::integer[], 'INCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('WINNER_NOTIFICATION', 'RESULT', 'IMMEDIATE', array[]::integer[], 'INCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"WINNER","scope":"CYCLE"},{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('PAYOUT_NOTIFICATION', 'FINANCIAL', 'IMMEDIATE', array[]::integer[], 'INCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"WINNER","scope":"PAYOUT"},{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('EXIT_REQUEST', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('EXIT_APPROVAL', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('EXIT_SETTLEMENT', 'FINANCIAL', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('DEATH_REPORT', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('DEATH_VERIFICATION', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('SUCCESSION', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"},{"type":"SUCCESSOR","scope":"MEMBERSHIP"}]}'::jsonb),
  ('ADMIN_POSITION_REQUEST', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EXCLUDE', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"ORGANIZATION"}]}'::jsonb),
  ('JOIN_REQUEST', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EXCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('INVITATION_RESPONSE', 'REQUEST', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('KURI_SCHEDULE_CHANGED', 'LIFECYCLE', 'IMMEDIATE', array[]::integer[], 'EXCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('KURI_ANNOUNCEMENT', 'BROADCAST', 'BROADCAST', array[]::integer[], 'INCLUDE', 'INVITATION_CLAIM',
   '{"audiences":[{"type":"KURI_MEMBER","scope":"KURI"},{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('ADMIN_SECURITY', 'SECURITY', 'IMMEDIATE', array[]::integer[], 'EVENT_SPECIFIC', 'NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"ORGANIZATION"}]}'::jsonb)
on conflict (event_type) do update
set category = excluded.category,
    timing_kind = excluded.timing_kind,
    reminder_offsets_days = excluded.reminder_offsets_days,
    actor_policy = excluded.actor_policy,
    no_user_policy = excluded.no_user_policy,
    recipient_rules = excluded.recipient_rules,
    default_channels = excluded.default_channels,
    enabled = true,
    updated_at = now();

revoke all on function public.notification_event_policies from public, anon, authenticated;
