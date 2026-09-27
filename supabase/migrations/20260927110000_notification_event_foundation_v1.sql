-- NOTIFICATION-001: durable notification event/outbox foundation.
-- This checkpoint establishes the durable event and in-app notification primitives.
-- Recipient policy, domain producers, scheduled producers, and delivery dispatch
-- are reconciled in later checkpoints.
BEGIN;

CREATE TABLE IF NOT EXISTS public.notification_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kuri_id uuid REFERENCES public.kuris(id) ON DELETE RESTRICT,
  actor_user_id uuid REFERENCES public.users(id) ON DELETE RESTRICT,
  event_type text NOT NULL,
  aggregate_type text,
  aggregate_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notification_events_type_check CHECK (
    event_type IN (
      'KURI_START_REMINDER','KURI_END_DATE_REMINDER','ENROLLMENT_REMINDER',
      'CYCLE_REMINDER','PAYMENT_REMINDER','LATE_PAYMENT_ALERT',
      'LATE_FEE_ACTIVATED','LATE_FEE_CHANGED','DRAW_PREPARATION',
      'DRAW_RESULT','WINNER_NOTIFICATION','PAYOUT_NOTIFICATION',
      'EXIT_REQUEST','EXIT_APPROVAL','EXIT_SETTLEMENT','DEATH_VERIFICATION',
      'SUCCESSION','ADMIN_SECURITY'
    )
  ),
  CONSTRAINT notification_events_payload_object_check
    CHECK (jsonb_typeof(payload)='object')
);

CREATE INDEX IF NOT EXISTS notification_events_org_created_idx
  ON public.notification_events(organization_id,created_at DESC);
CREATE INDEX IF NOT EXISTS notification_events_kuri_created_idx
  ON public.notification_events(kuri_id,created_at DESC);
CREATE INDEX IF NOT EXISTS notification_events_type_created_idx
  ON public.notification_events(event_type,created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS notification_events_idempotency_uniq
  ON public.notification_events(organization_id,idempotency_key)
  WHERE idempotency_key IS NOT NULL;

ALTER TABLE public.notification_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.notification_events FROM PUBLIC,anon,authenticated;

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.notification_events(id) ON DELETE RESTRICT,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  recipient_user_id uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  channel text NOT NULL DEFAULT 'IN_APP',
  status text NOT NULL DEFAULT 'PENDING',
  title text NOT NULL,
  body text NOT NULL,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  queued_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  failed_at timestamptz,
  read_at timestamptz,
  attempt_count integer NOT NULL DEFAULT 0,
  last_error text,
  CONSTRAINT notifications_channel_check CHECK (channel IN ('IN_APP','EMAIL','SMS','PUSH')),
  CONSTRAINT notifications_status_check CHECK (status IN ('PENDING','PROCESSING','SENT','FAILED','READ')),
  CONSTRAINT notifications_attempt_count_check CHECK (attempt_count>=0),
  CONSTRAINT notifications_data_object_check CHECK (jsonb_typeof(data)='object')
);

CREATE INDEX IF NOT EXISTS notifications_recipient_status_idx
  ON public.notifications(recipient_user_id,status,created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_org_created_idx
  ON public.notifications(organization_id,created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_event_idx
  ON public.notifications(event_id);
CREATE UNIQUE INDEX IF NOT EXISTS notifications_event_recipient_channel_uniq
  ON public.notifications(event_id,recipient_user_id,channel);

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.notifications FROM PUBLIC,anon;
GRANT SELECT ON TABLE public.notifications TO authenticated;

DROP POLICY IF EXISTS notifications_select_own ON public.notifications;
CREATE POLICY notifications_select_own
ON public.notifications FOR SELECT TO authenticated
USING (recipient_user_id=auth.uid());

CREATE OR REPLACE FUNCTION public.record_notification_event_for_admin(
  target_kuri_id uuid,
  event_type_value text,
  aggregate_type_value text DEFAULT NULL,
  aggregate_id_value uuid DEFAULT NULL,
  payload_value jsonb DEFAULT '{}'::jsonb,
  idempotency_key_value text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_org_id uuid;
  v_event_id uuid;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Kuri is required.'; END IF;
  IF event_type_value IS NULL OR event_type_value NOT IN (
    'KURI_START_REMINDER','KURI_END_DATE_REMINDER','ENROLLMENT_REMINDER',
    'CYCLE_REMINDER','PAYMENT_REMINDER','LATE_PAYMENT_ALERT',
    'LATE_FEE_ACTIVATED','LATE_FEE_CHANGED','DRAW_PREPARATION',
    'DRAW_RESULT','WINNER_NOTIFICATION','PAYOUT_NOTIFICATION',
    'EXIT_REQUEST','EXIT_APPROVAL','EXIT_SETTLEMENT','DEATH_VERIFICATION',
    'SUCCESSION','ADMIN_SECURITY'
  ) THEN
    RAISE EXCEPTION 'Unsupported notification event type.';
  END IF;
  IF payload_value IS NULL OR jsonb_typeof(payload_value)<>'object' THEN
    RAISE EXCEPTION 'Notification event payload must be a JSON object.';
  END IF;
  IF NOT public.has_kuri_admin_role(
    target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to create notification events for this Kuri.';
  END IF;
  SELECT k.organization_id INTO v_org_id
  FROM public.kuris k WHERE k.id=target_kuri_id;
  IF v_org_id IS NULL THEN RAISE EXCEPTION 'Kuri not found.'; END IF;

  IF idempotency_key_value IS NOT NULL THEN
    SELECT e.id INTO v_event_id
    FROM public.notification_events e
    WHERE e.organization_id=v_org_id
      AND e.idempotency_key=idempotency_key_value
    LIMIT 1;
    IF v_event_id IS NOT NULL THEN RETURN v_event_id; END IF;
  END IF;

  INSERT INTO public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  VALUES(
    v_org_id,target_kuri_id,v_actor,event_type_value,
    aggregate_type_value,aggregate_id_value,payload_value,idempotency_key_value
  )
  RETURNING id INTO v_event_id;
  RETURN v_event_id;
EXCEPTION WHEN unique_violation THEN
  IF idempotency_key_value IS NOT NULL THEN
    SELECT e.id INTO v_event_id
    FROM public.notification_events e
    WHERE e.organization_id=v_org_id
      AND e.idempotency_key=idempotency_key_value
    LIMIT 1;
    IF v_event_id IS NOT NULL THEN RETURN v_event_id; END IF;
  END IF;
  RAISE;
END;
$function$;

REVOKE ALL ON FUNCTION public.record_notification_event_for_admin(
  uuid,text,text,uuid,jsonb,text
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.record_notification_event_for_admin(
  uuid,text,text,uuid,jsonb,text
) TO authenticated;

CREATE OR REPLACE FUNCTION public.create_notification_for_admin(
  target_event_id uuid,
  target_user_id uuid,
  title_value text,
  body_value text,
  channel_value text DEFAULT 'IN_APP',
  data_value jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_event public.notification_events%rowtype;
  v_notification_id uuid;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF target_event_id IS NULL OR target_user_id IS NULL THEN
    RAISE EXCEPTION 'Event and recipient are required.';
  END IF;
  IF title_value IS NULL OR char_length(btrim(title_value))=0 THEN
    RAISE EXCEPTION 'Notification title is required.';
  END IF;
  IF body_value IS NULL OR char_length(btrim(body_value))=0 THEN
    RAISE EXCEPTION 'Notification body is required.';
  END IF;
  IF channel_value IS NULL OR channel_value NOT IN ('IN_APP','EMAIL','SMS','PUSH') THEN
    RAISE EXCEPTION 'Unsupported notification channel.';
  END IF;
  IF data_value IS NULL OR jsonb_typeof(data_value)<>'object' THEN
    RAISE EXCEPTION 'Notification data must be a JSON object.';
  END IF;

  SELECT * INTO v_event
  FROM public.notification_events e WHERE e.id=target_event_id;
  IF v_event.id IS NULL THEN RAISE EXCEPTION 'Notification event not found.'; END IF;
  IF NOT public.has_kuri_admin_role(
    v_event.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to create notifications for this event.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organization_users ou
    WHERE ou.organization_id=v_event.organization_id
      AND ou.user_id=target_user_id
  ) THEN
    RAISE EXCEPTION 'Notification recipient is not a member of this organization.';
  END IF;

  INSERT INTO public.notifications(
    event_id,organization_id,recipient_user_id,channel,status,title,body,data
  )
  VALUES(
    target_event_id,v_event.organization_id,target_user_id,channel_value,
    'PENDING',btrim(title_value),body_value,data_value
  )
  ON CONFLICT(event_id,recipient_user_id,channel)
  DO UPDATE SET title=excluded.title,body=excluded.body,data=excluded.data
  RETURNING id INTO v_notification_id;
  RETURN v_notification_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_notification_for_admin(
  uuid,uuid,text,text,text,jsonb
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_notification_for_admin(
  uuid,uuid,text,text,text,jsonb
) TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_notification_read(target_notification_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  UPDATE public.notifications
  SET status='READ',read_at=coalesce(read_at,now())
  WHERE id=target_notification_id AND recipient_user_id=auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Notification not found.'; END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.mark_notification_read(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.mark_notification_read(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.list_my_notifications(
  limit_value integer DEFAULT 50,
  offset_value integer DEFAULT 0
)
RETURNS TABLE(
  id uuid,event_id uuid,event_type text,channel text,status text,
  title text,body text,data jsonb,created_at timestamptz,
  sent_at timestamptz,read_at timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $function$
  SELECT n.id,n.event_id,e.event_type,n.channel,n.status,n.title,n.body,
         n.data,n.created_at,n.sent_at,n.read_at
  FROM public.notifications n
  JOIN public.notification_events e ON e.id=n.event_id
  WHERE n.recipient_user_id=auth.uid()
  ORDER BY n.created_at DESC
  LIMIT greatest(1,least(coalesce(limit_value,50),100))
  OFFSET greatest(coalesce(offset_value,0),0);
$function$;

REVOKE ALL ON FUNCTION public.list_my_notifications(integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_my_notifications(integer,integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_pending_notification_for_delivery(
  target_notification_id uuid
)
RETURNS TABLE(
  notification_id uuid,event_id uuid,recipient_user_id uuid,
  channel text,title text,body text,data jsonb,attempt_count integer
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  RETURN QUERY
  UPDATE public.notifications n
  SET status='PROCESSING',attempt_count=n.attempt_count+1
  WHERE n.id=target_notification_id AND n.status='PENDING'
  RETURNING n.id,n.event_id,n.recipient_user_id,n.channel,n.title,
            n.body,n.data,n.attempt_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.claim_pending_notification_for_delivery(uuid)
  FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.complete_notification_delivery(
  target_notification_id uuid,
  delivery_succeeded boolean,
  error_message text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF delivery_succeeded THEN
    UPDATE public.notifications
    SET status='SENT',sent_at=coalesce(sent_at,now()),
        failed_at=NULL,last_error=NULL
    WHERE id=target_notification_id AND status='PROCESSING';
  ELSE
    UPDATE public.notifications
    SET status='FAILED',failed_at=now(),
        last_error=nullif(btrim(coalesce(error_message,'')),'')
    WHERE id=target_notification_id AND status='PROCESSING';
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Notification is not in PROCESSING state.';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.complete_notification_delivery(uuid,boolean,text)
  FROM PUBLIC,anon,authenticated;

COMMIT;
