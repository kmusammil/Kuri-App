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