-- NOTIFICATION-002: recipient policy and event catalog v1.
-- Defines audience/scope semantics and timing without coupling domain actions
-- to delivery dispatch. Delivery remains IN_APP-first.
BEGIN;

ALTER TABLE public.notification_events
  DROP CONSTRAINT IF EXISTS notification_events_type_check;

ALTER TABLE public.notification_events
  ADD CONSTRAINT notification_events_type_check
  CHECK (
    event_type = ANY (
      ARRAY[
        'KURI_START_REMINDER','KURI_END_DATE_REMINDER','ENROLLMENT_REMINDER',
        'CYCLE_REMINDER','PAYMENT_REMINDER','LATE_PAYMENT_ALERT',
        'LATE_FEE_ACTIVATED','LATE_FEE_CHANGED','DRAW_PREPARATION',
        'DRAW_RESULT','WINNER_NOTIFICATION','PAYOUT_NOTIFICATION',
        'EXIT_REQUEST','EXIT_APPROVAL','EXIT_SETTLEMENT','DEATH_REPORT',
        'DEATH_VERIFICATION','SUCCESSION','ADMIN_POSITION_REQUEST',
        'JOIN_REQUEST','INVITATION_RESPONSE','KURI_SCHEDULE_CHANGED',
        'KURI_ANNOUNCEMENT','ADMIN_SECURITY'
      ]::text[]
    )
  );

CREATE TABLE IF NOT EXISTS public.notification_event_policies (
  event_type text PRIMARY KEY,
  category text NOT NULL,
  timing_kind text NOT NULL,
  reminder_offsets_days integer[] NOT NULL DEFAULT '{}'::integer[],
  actor_policy text NOT NULL DEFAULT 'EXCLUDE'
    CHECK (actor_policy IN ('EXCLUDE','INCLUDE','EVENT_SPECIFIC')),
  no_user_policy text NOT NULL DEFAULT 'NO_APP_NOTIFICATION'
    CHECK (no_user_policy IN ('NO_APP_NOTIFICATION','INVITATION_CLAIM','EVENT_SPECIFIC')),
  recipient_rules jsonb NOT NULL,
  default_channels text[] NOT NULL DEFAULT ARRAY['IN_APP']::text[],
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_event_policies_category_check
    CHECK (category IN ('REMINDER','REQUEST','RESULT','FINANCIAL','LIFECYCLE','SECURITY','BROADCAST')),
  CONSTRAINT notification_event_policies_timing_check
    CHECK (timing_kind IN ('IMMEDIATE','SCHEDULED','CONFIRMATION','BROADCAST')),
  CONSTRAINT notification_event_policies_offsets_check
    CHECK (
      (timing_kind <> 'SCHEDULED' AND cardinality(reminder_offsets_days) = 0)
      OR
      (timing_kind = 'SCHEDULED' AND cardinality(reminder_offsets_days) > 0)
    ),
  CONSTRAINT notification_event_policies_rules_object_check
    CHECK (jsonb_typeof(recipient_rules) = 'object'),
  CONSTRAINT notification_event_policies_channels_check
    CHECK (
      default_channels <@ ARRAY['IN_APP','PUSH','EMAIL','SMS']::text[]
      AND cardinality(default_channels) > 0
    )
);

ALTER TABLE public.notification_event_policies ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.notification_event_policies FROM anon, authenticated;

INSERT INTO public.notification_event_policies
  (event_type,category,timing_kind,reminder_offsets_days,actor_policy,no_user_policy,recipient_rules)
VALUES
  ('KURI_START_REMINDER','REMINDER','SCHEDULED',ARRAY[1],'INCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('KURI_END_DATE_REMINDER','REMINDER','SCHEDULED',ARRAY[7,1],'INCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('ENROLLMENT_REMINDER','REMINDER','SCHEDULED',ARRAY[3],'INCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('CYCLE_REMINDER','REMINDER','SCHEDULED',ARRAY[1],'INCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('PAYMENT_REMINDER','REMINDER','SCHEDULED',ARRAY[3,0],'INCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"KURI_MEMBER","scope":"MEMBERSHIP_WITH_OUTSTANDING_INSTALLMENT"}]}'::jsonb),
  ('LATE_PAYMENT_ALERT','FINANCIAL','SCHEDULED',ARRAY[1],'INCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"MEMBERSHIP_WITH_UNPAID_INSTALLMENT"}]}'::jsonb),
  ('LATE_FEE_ACTIVATED','FINANCIAL','IMMEDIATE',ARRAY[]::integer[],'INCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('LATE_FEE_CHANGED','FINANCIAL','IMMEDIATE',ARRAY[]::integer[],'INCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('DRAW_PREPARATION','REMINDER','SCHEDULED',ARRAY[1],'INCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('DRAW_RESULT','RESULT','IMMEDIATE',ARRAY[]::integer[],'INCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('WINNER_NOTIFICATION','RESULT','IMMEDIATE',ARRAY[]::integer[],'INCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"WINNER","scope":"CYCLE"},{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('PAYOUT_NOTIFICATION','FINANCIAL','IMMEDIATE',ARRAY[]::integer[],'INCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"WINNER","scope":"PAYOUT"},{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('EXIT_REQUEST','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('EXIT_APPROVAL','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('EXIT_SETTLEMENT','FINANCIAL','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('DEATH_REPORT','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('DEATH_VERIFICATION','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"}]}'::jsonb),
  ('SUCCESSION','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"CURRENT_HOLDER","scope":"MEMBERSHIP"},{"type":"SUCCESSOR","scope":"MEMBERSHIP"}]}'::jsonb),
  ('ADMIN_POSITION_REQUEST','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EXCLUDE','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"ORGANIZATION"}]}'::jsonb),
  ('JOIN_REQUEST','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EXCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('INVITATION_RESPONSE','REQUEST','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('KURI_SCHEDULE_CHANGED','LIFECYCLE','IMMEDIATE',ARRAY[]::integer[],'EXCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"},{"type":"KURI_MEMBER","scope":"KURI"}]}'::jsonb),
  ('KURI_ANNOUNCEMENT','BROADCAST','BROADCAST',ARRAY[]::integer[],'INCLUDE','INVITATION_CLAIM',
   '{"audiences":[{"type":"KURI_MEMBER","scope":"KURI"},{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"KURI"}]}'::jsonb),
  ('ADMIN_SECURITY','SECURITY','IMMEDIATE',ARRAY[]::integer[],'EVENT_SPECIFIC','NO_APP_NOTIFICATION',
   '{"audiences":[{"type":"MAIN_ADMIN","scope":"ORGANIZATION"},{"type":"ADMIN","scope":"ORGANIZATION"}]}'::jsonb)
ON CONFLICT (event_type) DO UPDATE
SET category=excluded.category,
    timing_kind=excluded.timing_kind,
    reminder_offsets_days=excluded.reminder_offsets_days,
    actor_policy=excluded.actor_policy,
    no_user_policy=excluded.no_user_policy,
    recipient_rules=excluded.recipient_rules,
    default_channels=excluded.default_channels,
    enabled=true,
    updated_at=now();

COMMIT;
