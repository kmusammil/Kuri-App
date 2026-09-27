-- NOTIFICATION-003: policy-driven notification dispatch v1.
-- Resolves recipient User IDs from notification_event_policies.
-- Delivery remains IN_APP-first; no external provider is invoked here.
BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

CREATE OR REPLACE FUNCTION public.dispatch_notification_events_for_delivery(
  batch_size integer DEFAULT 200
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_inserted integer := 0;
BEGIN
  IF batch_size IS NULL OR batch_size < 1 OR batch_size > 1000 THEN
    RAISE EXCEPTION 'batch_size must be between 1 and 1000';
  END IF;

  WITH pending_events AS (
    SELECT
      ne.*,
      nep.actor_policy,
      nep.recipient_rules,
      nep.default_channels
    FROM public.notification_events ne
    JOIN public.notification_event_policies nep
      ON nep.event_type = ne.event_type
     AND nep.enabled
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.notifications n
      WHERE n.event_id = ne.id
    )
    ORDER BY ne.created_at, ne.id
    LIMIT batch_size
  ),
  audience_rules AS (
    SELECT
      pe.id AS event_id,
      pe.organization_id,
      pe.kuri_id,
      pe.actor_user_id,
      pe.event_type,
      pe.payload,
      pe.actor_policy,
      pe.default_channels,
      ar->>'type' AS audience_type,
      ar->>'scope' AS audience_scope
    FROM pending_events pe
    CROSS JOIN LATERAL jsonb_array_elements(
      coalesce(pe.recipient_rules->'audiences', '[]'::jsonb)
    ) ar
  ),
  recipient_users AS (
    SELECT
      a.event_id, a.organization_id, ou.user_id AS recipient_user_id,
      a.default_channels
    FROM audience_rules a
    JOIN public.organization_users ou
      ON ou.organization_id = a.organization_id
     AND ou.role = 'MAIN_ADMIN'::public.app_role
    WHERE a.audience_type = 'MAIN_ADMIN'
      AND a.audience_scope = 'ORGANIZATION'

    UNION ALL

    SELECT
      a.event_id, a.organization_id, ou.user_id,
      a.default_channels
    FROM audience_rules a
    JOIN public.organization_users ou
      ON ou.organization_id = a.organization_id
     AND ou.role = 'ADMIN'::public.app_role
    WHERE a.audience_type = 'ADMIN'
      AND a.audience_scope = 'ORGANIZATION'

    UNION ALL

    SELECT
      a.event_id, a.organization_id, ka.user_id,
      a.default_channels
    FROM audience_rules a
    JOIN public.kuri_admins ka
      ON ka.kuri_id = a.kuri_id
     AND ka.role = 'ADMIN'::public.kuri_admin_role
    WHERE a.audience_type = 'ADMIN'
      AND a.audience_scope = 'KURI'

    UNION ALL

    SELECT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.memberships m
      ON m.kuri_id = a.kuri_id
     AND m.status = 'ACTIVE'::public.membership_status
    JOIN public.users u
      ON u.person_id = m.person_id
    WHERE a.audience_type = 'KURI_MEMBER'
      AND a.audience_scope = 'KURI'

    UNION ALL

    SELECT DISTINCT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.installments i
      ON (
        i.membership_id = nullif(a.payload->>'membership_id','')::uuid
        OR i.id = nullif(a.payload->>'installment_id','')::uuid
      )
    JOIN public.memberships m
      ON m.id = i.membership_id
     AND m.kuri_id = a.kuri_id
     AND m.status = 'ACTIVE'::public.membership_status
    JOIN public.users u
      ON u.person_id = m.person_id
    WHERE a.audience_type = 'KURI_MEMBER'
      AND a.audience_scope = 'MEMBERSHIP_WITH_OUTSTANDING_INSTALLMENT'
      AND i.amount_due > i.amount_paid

    UNION ALL

    SELECT DISTINCT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.installments i
      ON (
        i.membership_id = nullif(a.payload->>'membership_id','')::uuid
        OR i.id = nullif(a.payload->>'installment_id','')::uuid
      )
    JOIN public.memberships m
      ON m.id = i.membership_id
     AND m.kuri_id = a.kuri_id
     AND m.status = 'ACTIVE'::public.membership_status
    JOIN public.users u
      ON u.person_id = m.person_id
    WHERE a.audience_type = 'KURI_MEMBER'
      AND a.audience_scope = 'MEMBERSHIP_WITH_UNPAID_INSTALLMENT'
      AND i.amount_due > i.amount_paid
      AND i.due_date < current_date

    UNION ALL

    SELECT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.users u
      ON u.person_id = nullif(a.payload->>'person_id','')::uuid
    WHERE a.audience_type = 'WINNER'
      AND a.audience_scope = 'CYCLE'

    UNION ALL

    SELECT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.payouts p
      ON p.id = nullif(a.payload->>'payout_id','')::uuid
    JOIN public.monthly_winners mw
      ON mw.id = p.monthly_winner_id
    JOIN public.users u
      ON u.person_id = mw.person_id
    WHERE a.audience_type = 'WINNER'
      AND a.audience_scope = 'PAYOUT'

    UNION ALL

    SELECT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.membership_exits me
      ON me.id = nullif(a.payload->>'exit_id','')::uuid
    JOIN public.memberships m
      ON m.id = me.membership_id
     AND m.kuri_id = a.kuri_id
    JOIN public.users u
      ON u.person_id = m.current_holder_person_id
    WHERE a.audience_type = 'CURRENT_HOLDER'
      AND a.audience_scope = 'MEMBERSHIP'

    UNION ALL

    SELECT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.memberships m
      ON m.id = nullif(a.payload->>'membership_id','')::uuid
     AND m.kuri_id = a.kuri_id
    JOIN public.users u
      ON u.person_id = m.current_holder_person_id
    WHERE a.audience_type = 'CURRENT_HOLDER'
      AND a.audience_scope = 'MEMBERSHIP'

    UNION ALL

    SELECT
      a.event_id, a.organization_id, u.id,
      a.default_channels
    FROM audience_rules a
    JOIN public.users u
      ON u.person_id = nullif(a.payload->>'successor_person_id','')::uuid
    WHERE a.audience_type = 'SUCCESSOR'
      AND a.audience_scope = 'MEMBERSHIP'
  ),
  deduplicated_recipients AS (
    SELECT DISTINCT
      ru.event_id,
      ru.organization_id,
      ru.recipient_user_id,
      channel
    FROM recipient_users ru
    CROSS JOIN LATERAL unnest(ru.default_channels) channel
    WHERE channel = ANY (ARRAY['IN_APP','PUSH','EMAIL','SMS']::text[])
      AND NOT EXISTS (
        SELECT 1
        FROM pending_events pe
        WHERE pe.id = ru.event_id
          AND pe.actor_policy = 'EXCLUDE'
          AND pe.actor_user_id = ru.recipient_user_id
      )
  ),
  inserted AS (
    INSERT INTO public.notifications (
      event_id, organization_id, recipient_user_id, channel,
      status, title, body, data, created_at, queued_at, sent_at, attempt_count
    )
    SELECT
      r.event_id,
      r.organization_id,
      r.recipient_user_id,
      r.channel,
      'SENT',
      CASE pe.event_type
        WHEN 'DRAW_PREPARATION' THEN 'Draw preparation required'
        WHEN 'DRAW_RESULT' THEN 'Draw result finalized'
        WHEN 'WINNER_NOTIFICATION' THEN 'Winner notification'
        WHEN 'PAYOUT_NOTIFICATION' THEN 'Payout update'
        WHEN 'EXIT_REQUEST' THEN 'Membership exit requested'
        WHEN 'EXIT_APPROVAL' THEN 'Membership exit approved'
        WHEN 'EXIT_SETTLEMENT' THEN 'Membership exit settled'
        WHEN 'DEATH_REPORT' THEN 'Death report recorded'
        WHEN 'DEATH_VERIFICATION' THEN 'Death verification recorded'
        WHEN 'SUCCESSION' THEN 'Membership succession recorded'
        WHEN 'LATE_FEE_ACTIVATED' THEN 'Late fee activated'
        WHEN 'LATE_FEE_CHANGED' THEN 'Late fee configuration changed'
        WHEN 'JOIN_REQUEST' THEN 'Join request received'
        WHEN 'ADMIN_POSITION_REQUEST' THEN 'Admin position request received'
        WHEN 'KURI_SCHEDULE_CHANGED' THEN 'Kuri schedule changed'
        WHEN 'KURI_ANNOUNCEMENT' THEN 'Kuri announcement'
        WHEN 'PAYMENT_REMINDER' THEN 'Payment reminder'
        WHEN 'LATE_PAYMENT_ALERT' THEN 'Late payment alert'
        ELSE replace(initcap(lower(replace(pe.event_type, '_', ' '))), 'Notification', '')
      END,
      CASE pe.event_type
        WHEN 'DRAW_PREPARATION' THEN 'A cycle has reached draw preparation.'
        WHEN 'DRAW_RESULT' THEN 'A draw result has been finalized.'
        WHEN 'WINNER_NOTIFICATION' THEN 'A winner has been finalized.'
        WHEN 'PAYOUT_NOTIFICATION' THEN 'A payout status has changed.'
        WHEN 'EXIT_REQUEST' THEN 'A membership exit request was recorded.'
        WHEN 'EXIT_APPROVAL' THEN 'A membership exit was approved.'
        WHEN 'EXIT_SETTLEMENT' THEN 'A membership exit was settled.'
        WHEN 'DEATH_REPORT' THEN 'A death report was recorded.'
        WHEN 'DEATH_VERIFICATION' THEN 'A death date was verified for a membership exit.'
        WHEN 'SUCCESSION' THEN 'A membership succession was recorded.'
        WHEN 'LATE_FEE_ACTIVATED' THEN 'A late-fee rule was activated.'
        WHEN 'LATE_FEE_CHANGED' THEN 'A late-fee rule was changed.'
        WHEN 'JOIN_REQUEST' THEN 'A join request requires review.'
        WHEN 'ADMIN_POSITION_REQUEST' THEN 'An admin position request requires review.'
        WHEN 'KURI_SCHEDULE_CHANGED' THEN 'The Kuri schedule has changed.'
        WHEN 'KURI_ANNOUNCEMENT' THEN 'A new Kuri announcement is available.'
        WHEN 'PAYMENT_REMINDER' THEN 'An installment payment is due or approaching.'
        WHEN 'LATE_PAYMENT_ALERT' THEN 'An installment remains unpaid after its due date.'
        ELSE 'A Kuri event requires your attention.'
      END,
      coalesce(pe.payload, '{}'::jsonb),
      now(), now(), now(), 0
    FROM deduplicated_recipients r
    JOIN pending_events pe ON pe.id = r.event_id
    ON CONFLICT (event_id, recipient_user_id, channel) DO NOTHING
    RETURNING id
  )
  SELECT count(*) INTO v_inserted FROM inserted;

  RETURN v_inserted;
END;
$function$;

REVOKE ALL ON FUNCTION public.dispatch_notification_events_for_delivery(integer)
  FROM PUBLIC, anon, authenticated;

SELECT cron.schedule(
  'kuri-notification-event-dispatch',
  '* * * * *',
  $$SELECT public.dispatch_notification_events_for_delivery(200);$$
);

COMMIT;
