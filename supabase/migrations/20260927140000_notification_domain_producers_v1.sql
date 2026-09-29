-- NOTIFICATION-004: domain event producers v1.
-- Connects existing domain state changes to durable notification events.
-- Scheduled reminder generation and external delivery remain separate checkpoints.
BEGIN;

CREATE OR REPLACE FUNCTION public.emit_notification_event_internal(
  target_kuri_id uuid,
  event_type_value text,
  aggregate_type_value text,
  aggregate_id_value uuid,
  payload_value jsonb,
  idempotency_key_value text,
  actor_user_id_value uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $function$
DECLARE
  v_org_id uuid;
  v_event_id uuid;
  v_actor uuid;
BEGIN
  SELECT k.organization_id INTO v_org_id
  FROM public.kuris k WHERE k.id=target_kuri_id;
  IF v_org_id IS NULL THEN RETURN NULL; END IF;
  v_actor:=coalesce(actor_user_id_value,auth.uid());

  INSERT INTO public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  VALUES(
    v_org_id,target_kuri_id,v_actor,event_type_value,
    aggregate_type_value,aggregate_id_value,
    coalesce(payload_value,'{}'::jsonb),idempotency_key_value
  )
  ON CONFLICT (organization_id,idempotency_key)
    WHERE idempotency_key IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_event_id;

  IF v_event_id IS NULL THEN
    SELECT e.id INTO v_event_id
    FROM public.notification_events e
    WHERE e.organization_id=v_org_id
      AND e.idempotency_key=idempotency_key_value
    LIMIT 1;
  END IF;
  RETURN v_event_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.emit_notification_event_internal(
  uuid,text,text,uuid,jsonb,text,uuid
) FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_cycle_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
BEGIN
  IF tg_op='UPDATE' AND new.status IS DISTINCT FROM old.status
     AND new.status='DRAW_PENDING' THEN
    PERFORM public.emit_notification_event_internal(
      new.kuri_id,'DRAW_PREPARATION','cycle',new.id,
      jsonb_build_object('cycle_id',new.id,'cycle_number',new.cycle_number,'status',new.status),
      'cycle:'||new.id::text||':DRAW_PREPARATION:'||new.status::text
    );
  END IF;
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_cycle_notification_event ON public.cycles;
CREATE TRIGGER emit_cycle_notification_event
AFTER UPDATE OF status ON public.cycles
FOR EACH ROW EXECUTE FUNCTION public.emit_cycle_notification_event();
REVOKE ALL ON FUNCTION public.emit_cycle_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_winner_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_kuri_id uuid;
BEGIN
  SELECT c.kuri_id INTO v_kuri_id FROM public.cycles c WHERE c.id=new.cycle_id;
  IF tg_op='INSERT' OR (tg_op='UPDATE' AND new.finalized_at IS DISTINCT FROM old.finalized_at) THEN
    IF new.finalized_at IS NOT NULL THEN
      PERFORM public.emit_notification_event_internal(
        v_kuri_id,'DRAW_RESULT','monthly_winner',new.id,
        jsonb_build_object('winner_id',new.id,'cycle_id',new.cycle_id,'person_id',new.person_id,
          'selection_source',new.selection_source,'finalized_at',new.finalized_at),
        'winner:'||new.id::text||':DRAW_RESULT'
      );
      PERFORM public.emit_notification_event_internal(
        v_kuri_id,'WINNER_NOTIFICATION','monthly_winner',new.id,
        jsonb_build_object('winner_id',new.id,'cycle_id',new.cycle_id,'person_id',new.person_id),
        'winner:'||new.id::text||':WINNER_NOTIFICATION'
      );
    END IF;
  END IF;
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_winner_notification_event ON public.monthly_winners;
CREATE TRIGGER emit_winner_notification_event
AFTER INSERT OR UPDATE OF finalized_at ON public.monthly_winners
FOR EACH ROW EXECUTE FUNCTION public.emit_winner_notification_event();
REVOKE ALL ON FUNCTION public.emit_winner_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_payout_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_kuri_id uuid;
BEGIN
  SELECT c.kuri_id INTO v_kuri_id
  FROM public.monthly_winners mw JOIN public.cycles c ON c.id=mw.cycle_id
  WHERE mw.id=new.monthly_winner_id;

  IF tg_op='INSERT' THEN
    IF new.status IN ('PENDING','PROCESSING','PAID') THEN
      PERFORM public.emit_notification_event_internal(
        v_kuri_id,'PAYOUT_NOTIFICATION','payout',new.id,
        jsonb_build_object('payout_id',new.id,'winner_id',new.monthly_winner_id,
          'status',new.status,'net_amount',new.net_amount),
        'payout:'||new.id::text||':status:'||new.status::text,new.processed_by
      );
    END IF;
  ELSIF tg_op='UPDATE' AND new.status IS DISTINCT FROM old.status THEN
    PERFORM public.emit_notification_event_internal(
      v_kuri_id,'PAYOUT_NOTIFICATION','payout',new.id,
      jsonb_build_object('payout_id',new.id,'winner_id',new.monthly_winner_id,
        'status',new.status,'net_amount',new.net_amount),
      'payout:'||new.id::text||':status:'||new.status::text,new.processed_by
    );
  END IF;
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_payout_notification_event ON public.payouts;
CREATE TRIGGER emit_payout_notification_event
AFTER INSERT OR UPDATE OF status ON public.payouts
FOR EACH ROW EXECUTE FUNCTION public.emit_payout_notification_event();
REVOKE ALL ON FUNCTION public.emit_payout_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_exit_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_kuri_id uuid; v_actor uuid;
BEGIN
  SELECT m.kuri_id INTO v_kuri_id FROM public.memberships m WHERE m.id=new.membership_id;
  v_actor:=coalesce(new.approved_by,new.death_date_verified_by,auth.uid());

  IF tg_op='INSERT' THEN
    PERFORM public.emit_notification_event_internal(
      v_kuri_id,'EXIT_REQUEST','membership_exit',new.id,
      jsonb_build_object('exit_id',new.id,'membership_id',new.membership_id,
        'reason',new.reason,'status',new.status,'exit_date',new.exit_date),
      'exit:'||new.id::text||':EXIT_REQUEST',v_actor
    );
  ELSIF tg_op='UPDATE' THEN
    IF new.status IS DISTINCT FROM old.status THEN
      IF new.status='APPROVED' THEN
        PERFORM public.emit_notification_event_internal(
          v_kuri_id,'EXIT_APPROVAL','membership_exit',new.id,
          jsonb_build_object('exit_id',new.id,'membership_id',new.membership_id,'status',new.status),
          'exit:'||new.id::text||':EXIT_APPROVAL',v_actor);
      ELSIF new.status='SETTLED' THEN
        PERFORM public.emit_notification_event_internal(
          v_kuri_id,'EXIT_SETTLEMENT','membership_exit',new.id,
          jsonb_build_object('exit_id',new.id,'membership_id',new.membership_id,
            'status',new.status,'settled_at',new.settled_at),
          'exit:'||new.id::text||':EXIT_SETTLEMENT',v_actor);
      END IF;
    END IF;
    IF new.death_date_verified_at IS DISTINCT FROM old.death_date_verified_at
       AND new.death_date_verified_at IS NOT NULL THEN
      PERFORM public.emit_notification_event_internal(
        v_kuri_id,'DEATH_VERIFICATION','membership_exit',new.id,
        jsonb_build_object('exit_id',new.id,'membership_id',new.membership_id,
          'death_date',new.death_date,'verified_at',new.death_date_verified_at),
        'exit:'||new.id::text||':DEATH_VERIFICATION',new.death_date_verified_by);
    END IF;
  END IF;
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_exit_notification_event ON public.membership_exits;
CREATE TRIGGER emit_exit_notification_event
AFTER INSERT OR UPDATE OF status,death_date_verified_at ON public.membership_exits
FOR EACH ROW EXECUTE FUNCTION public.emit_exit_notification_event();
REVOKE ALL ON FUNCTION public.emit_exit_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_succession_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_kuri_id uuid;
BEGIN
  SELECT m.kuri_id INTO v_kuri_id FROM public.memberships m WHERE m.id=new.membership_id;
  PERFORM public.emit_notification_event_internal(
    v_kuri_id,'SUCCESSION','membership_succession',new.id,
    jsonb_build_object('succession_id',new.id,'membership_id',new.membership_id,
      'membership_exit_id',new.membership_exit_id,'original_person_id',new.original_person_id,
      'successor_person_id',new.successor_person_id,'nominee_id',new.nominee_id),
    'succession:'||new.id::text||':SUCCESSION',new.recorded_by
  );
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_succession_notification_event ON public.membership_successions;
CREATE TRIGGER emit_succession_notification_event
AFTER INSERT ON public.membership_successions
FOR EACH ROW EXECUTE FUNCTION public.emit_succession_notification_event();
REVOKE ALL ON FUNCTION public.emit_succession_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_late_fee_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_event_type text; v_key text;
BEGIN
  IF tg_op='INSERT' THEN
    IF new.enabled THEN
      v_event_type:='LATE_FEE_ACTIVATED';
      v_key:='late-fee-rule:'||new.id::text||':ACTIVATED';
    ELSE RETURN new;
    END IF;
  ELSIF tg_op='UPDATE' THEN
    IF new.enabled AND NOT old.enabled THEN
      v_event_type:='LATE_FEE_ACTIVATED';
    ELSIF new.enabled OR old.enabled THEN
      v_event_type:='LATE_FEE_CHANGED';
    ELSE RETURN new;
    END IF;
    v_key:='late-fee-rule:'||new.id::text||':'||v_event_type||':'||new.updated_at::text;
  ELSE RETURN new;
  END IF;

  PERFORM public.emit_notification_event_internal(
    new.kuri_id,v_event_type,'kuri_late_fee_rule',new.id,
    jsonb_build_object('late_fee_rule_id',new.id,'enabled',new.enabled,
      'fee_type',new.fee_type,'fixed_amount',new.fixed_amount,
      'percentage_basis_points',new.percentage_basis_points,
      'grace_period_days',new.grace_period_days,
      'effective_from',new.effective_from,'effective_to',new.effective_to),
    v_key,new.created_by
  );
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_late_fee_notification_event ON public.kuri_late_fee_rules;
CREATE TRIGGER emit_late_fee_notification_event
AFTER INSERT OR UPDATE ON public.kuri_late_fee_rules
FOR EACH ROW EXECUTE FUNCTION public.emit_late_fee_notification_event();
REVOKE ALL ON FUNCTION public.emit_late_fee_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_join_request_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_actor uuid;
BEGIN
  v_actor:=coalesce(new.applicant_user_id,auth.uid());
  IF tg_op='INSERT' AND new.status::text='PENDING' THEN
    PERFORM public.emit_notification_event_internal(
      new.kuri_id,'JOIN_REQUEST','kuri_join_request',new.id,
      jsonb_build_object('join_request_id',new.id,'kuri_id',new.kuri_id,
        'applicant_user_id',new.applicant_user_id,'applicant_person_id',new.applicant_person_id,
        'status',new.status::text,'requested_at',new.requested_at),
      'join-request:'||new.id::text||':JOIN_REQUEST',v_actor);
  END IF;
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_join_request_notification_event ON public.kuri_join_requests;
CREATE TRIGGER emit_join_request_notification_event
AFTER INSERT ON public.kuri_join_requests
FOR EACH ROW EXECUTE FUNCTION public.emit_join_request_notification_event();
REVOKE ALL ON FUNCTION public.emit_join_request_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_invitation_response_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
BEGIN
  IF tg_op='UPDATE' AND old.status::text='PENDING' AND new.status::text='CONSUMED' THEN
    PERFORM public.emit_notification_event_internal(
      new.kuri_id,'INVITATION_RESPONSE','kuri_invitation',new.id,
      jsonb_build_object('invitation_id',new.id,'kuri_id',new.kuri_id,
        'recipient_user_id',new.recipient_user_id,'recipient_email',new.recipient_email,
        'recipient_phone',new.recipient_phone,'status',new.status::text,
        'consumed_at',new.consumed_at,'consumed_by',new.consumed_by),
      'invitation:'||new.id::text||':INVITATION_RESPONSE:CONSUMED',
      coalesce(new.consumed_by,auth.uid()));
  END IF;
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_invitation_response_notification_event ON public.kuri_invitations;
CREATE TRIGGER emit_invitation_response_notification_event
AFTER UPDATE OF status ON public.kuri_invitations
FOR EACH ROW EXECUTE FUNCTION public.emit_invitation_response_notification_event();
REVOKE ALL ON FUNCTION public.emit_invitation_response_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_kuri_schedule_changed_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_kuri_id uuid; v_actor uuid; v_payload jsonb; v_key text;
BEGIN
  IF tg_table_name='cycle_schedule_overrides' THEN
    v_kuri_id:=new.kuri_id; v_actor:=new.changed_by;
    v_payload:=jsonb_build_object('schedule_source','cycle_schedule_override',
      'override_id',new.id,'cycle_id',new.cycle_id,
      'previous_period_start',new.previous_period_start,'previous_period_end',new.previous_period_end,
      'previous_due_date',new.previous_due_date,'previous_draw_date',new.previous_draw_date,
      'new_period_start',new.new_period_start,'new_period_end',new.new_period_end,
      'new_due_date',new.new_due_date,'new_draw_date',new.new_draw_date,'reason',new.reason);
    v_key:='schedule-override:'||new.id::text||':KURI_SCHEDULE_CHANGED';
  ELSIF tg_table_name='kuri_custom_cycle_schedules' THEN
    v_kuri_id:=new.kuri_id; v_actor:=auth.uid();
    v_payload:=jsonb_build_object('schedule_source','custom_cycle_schedule',
      'schedule_id',new.id,'cycle_number',new.cycle_number,'period_start',new.period_start,
      'period_end',new.period_end,'due_date',new.due_date,'draw_date',new.draw_date);
    v_key:='custom-schedule:'||new.id::text||':KURI_SCHEDULE_CHANGED:'||
      coalesce(new.updated_at::text,new.created_at::text);
  ELSE
    v_kuri_id:=new.id; v_actor:=auth.uid();
    v_payload:=jsonb_build_object('schedule_source','kuri','kuri_id',new.id,
      'previous_start_date',old.start_date,'new_start_date',new.start_date,
      'previous_frequency',old.frequency::text,'new_frequency',new.frequency::text,
      'previous_due_day',old.due_day,'new_due_day',new.due_day,
      'previous_draw_day',old.draw_day,'new_draw_day',new.draw_day,
      'previous_number_of_cycles',old.number_of_cycles,'new_number_of_cycles',new.number_of_cycles,
      'previous_schedule_mode',old.schedule_mode::text,'new_schedule_mode',new.schedule_mode::text);
    v_key:='kuri-schedule:'||new.id::text||':KURI_SCHEDULE_CHANGED:'||new.updated_at::text;
  END IF;

  PERFORM public.emit_notification_event_internal(
    v_kuri_id,'KURI_SCHEDULE_CHANGED','kuri_schedule',v_kuri_id,v_payload,v_key,v_actor);
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_cycle_schedule_override_notification ON public.cycle_schedule_overrides;
CREATE TRIGGER emit_cycle_schedule_override_notification
AFTER INSERT ON public.cycle_schedule_overrides
FOR EACH ROW EXECUTE FUNCTION public.emit_kuri_schedule_changed_notification_event();

DROP TRIGGER IF EXISTS emit_custom_cycle_schedule_notification ON public.kuri_custom_cycle_schedules;
CREATE TRIGGER emit_custom_cycle_schedule_notification
AFTER INSERT OR UPDATE ON public.kuri_custom_cycle_schedules
FOR EACH ROW EXECUTE FUNCTION public.emit_kuri_schedule_changed_notification_event();

DROP TRIGGER IF EXISTS emit_kuri_schedule_changed_notification ON public.kuris;
CREATE TRIGGER emit_kuri_schedule_changed_notification
AFTER UPDATE OF start_date,frequency,due_day,draw_day,number_of_cycles,schedule_mode ON public.kuris
FOR EACH ROW
WHEN (
  old.start_date IS DISTINCT FROM new.start_date
  OR old.frequency IS DISTINCT FROM new.frequency
  OR old.due_day IS DISTINCT FROM new.due_day
  OR old.draw_day IS DISTINCT FROM new.draw_day
  OR old.number_of_cycles IS DISTINCT FROM new.number_of_cycles
  OR old.schedule_mode IS DISTINCT FROM new.schedule_mode
)
EXECUTE FUNCTION public.emit_kuri_schedule_changed_notification_event();
REVOKE ALL ON FUNCTION public.emit_kuri_schedule_changed_notification_event() FROM public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.emit_death_report_notification_event()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $function$
DECLARE v_kuri_id uuid;
BEGIN
  IF tg_op='INSERT' AND new.reason::text='DEATH' THEN
    SELECT m.kuri_id INTO v_kuri_id FROM public.memberships m WHERE m.id=new.membership_id;
    PERFORM public.emit_notification_event_internal(
      v_kuri_id,'DEATH_REPORT','membership_exit',new.id,
      jsonb_build_object('exit_id',new.id,'membership_id',new.membership_id,
        'reason',new.reason::text,'death_date',new.death_date,
        'status',new.status::text,'requested_at',new.requested_at),
      'exit:'||new.id::text||':DEATH_REPORT',auth.uid());
  END IF;
  RETURN new;
END;
$function$;

DROP TRIGGER IF EXISTS emit_death_report_notification_event ON public.membership_exits;
CREATE TRIGGER emit_death_report_notification_event
AFTER INSERT ON public.membership_exits
FOR EACH ROW EXECUTE FUNCTION public.emit_death_report_notification_event();
REVOKE ALL ON FUNCTION public.emit_death_report_notification_event() FROM public,anon,authenticated;

COMMIT;
