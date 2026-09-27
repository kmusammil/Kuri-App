begin;

-- NOTIFICATION-001 follow-up: wire durable domain events into the event outbox.
-- This records domain events only. Recipient selection and delivery remain
-- separate concerns handled by the notification APIs/worker.

create or replace function public.emit_notification_event_internal(
  target_kuri_id uuid,
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
  v_org_id uuid;
  v_event_id uuid;
  v_actor uuid;
begin
  select k.organization_id into v_org_id
  from public.kuris k
  where k.id=target_kuri_id;

  if v_org_id is null then
    return null;
  end if;

  v_actor:=coalesce(actor_user_id_value,auth.uid());

  insert into public.notification_events(
    organization_id,kuri_id,actor_user_id,event_type,
    aggregate_type,aggregate_id,payload,idempotency_key
  )
  values(
    v_org_id,target_kuri_id,v_actor,event_type_value,
    aggregate_type_value,aggregate_id_value,
    coalesce(payload_value,'{}'::jsonb),
    idempotency_key_value
  )
  on conflict (organization_id,idempotency_key)
    where idempotency_key is not null
  do nothing
  returning id into v_event_id;

  if v_event_id is null then
    select e.id into v_event_id
    from public.notification_events e
    where e.organization_id=v_org_id
      and e.idempotency_key=idempotency_key_value
    limit 1;
  end if;

  return v_event_id;
end;
$function$;

revoke all on function public.emit_notification_event_internal(uuid,text,text,uuid,jsonb,text,uuid)
  from public,anon,authenticated;

create or replace function public.emit_cycle_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
begin
  if tg_op='UPDATE' and new.status is distinct from old.status then
    if new.status='DRAW_PENDING' then
      perform public.emit_notification_event_internal(
        new.kuri_id,
        'DRAW_PREPARATION',
        'cycle',
        new.id,
        jsonb_build_object(
          'cycle_id',new.id,
          'cycle_number',new.cycle_number,
          'status',new.status
        ),
        'cycle:'||new.id::text||':DRAW_PREPARATION:'||new.status::text
      );
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists emit_cycle_notification_event on public.cycles;
create trigger emit_cycle_notification_event
after update of status on public.cycles
for each row execute function public.emit_cycle_notification_event();

revoke all on function public.emit_cycle_notification_event() from public,anon,authenticated;

create or replace function public.emit_winner_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_kuri_id uuid;
begin
  select c.kuri_id into v_kuri_id
  from public.cycles c
  where c.id=new.cycle_id;

  if tg_op='INSERT' or (tg_op='UPDATE' and new.finalized_at is distinct from old.finalized_at) then
    if new.finalized_at is not null then
      perform public.emit_notification_event_internal(
        v_kuri_id,
        'DRAW_RESULT',
        'monthly_winner',
        new.id,
        jsonb_build_object(
          'winner_id',new.id,
          'cycle_id',new.cycle_id,
          'person_id',new.person_id,
          'selection_source',new.selection_source,
          'finalized_at',new.finalized_at
        ),
        'winner:'||new.id::text||':DRAW_RESULT'
      );

      perform public.emit_notification_event_internal(
        v_kuri_id,
        'WINNER_NOTIFICATION',
        'monthly_winner',
        new.id,
        jsonb_build_object(
          'winner_id',new.id,
          'cycle_id',new.cycle_id,
          'person_id',new.person_id
        ),
        'winner:'||new.id::text||':WINNER_NOTIFICATION'
      );
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_winner_notification_event on public.monthly_winners;
create trigger emit_winner_notification_event
after insert or update of finalized_at on public.monthly_winners
for each row execute function public.emit_winner_notification_event();

revoke all on function public.emit_winner_notification_event() from public,anon,authenticated;

create or replace function public.emit_payout_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_kuri_id uuid;
begin
  select c.kuri_id into v_kuri_id
  from public.monthly_winners mw
  join public.cycles c on c.id=mw.cycle_id
  where mw.id=new.monthly_winner_id;

  if tg_op='INSERT' then
    if new.status in ('PENDING','PROCESSING','PAID') then
      perform public.emit_notification_event_internal(
        v_kuri_id,
        'PAYOUT_NOTIFICATION',
        'payout',
        new.id,
        jsonb_build_object(
          'payout_id',new.id,
          'winner_id',new.monthly_winner_id,
          'status',new.status,
          'net_amount',new.net_amount
        ),
        'payout:'||new.id::text||':status:'||new.status::text,
        new.processed_by
      );
    end if;
  elsif tg_op='UPDATE' and new.status is distinct from old.status then
    perform public.emit_notification_event_internal(
      v_kuri_id,
      'PAYOUT_NOTIFICATION',
      'payout',
      new.id,
      jsonb_build_object(
        'payout_id',new.id,
        'winner_id',new.monthly_winner_id,
        'status',new.status,
        'net_amount',new.net_amount
      ),
      'payout:'||new.id::text||':status:'||new.status::text,
      new.processed_by
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_payout_notification_event on public.payouts;
create trigger emit_payout_notification_event
after insert or update of status on public.payouts
for each row execute function public.emit_payout_notification_event();

revoke all on function public.emit_payout_notification_event() from public,anon,authenticated;

create or replace function public.emit_exit_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_kuri_id uuid;
  v_actor uuid;
begin
  select m.kuri_id into v_kuri_id
  from public.memberships m
  where m.id=new.membership_id;

  v_actor:=coalesce(new.approved_by,new.death_date_verified_by,auth.uid());

  if tg_op='INSERT' then
    perform public.emit_notification_event_internal(
      v_kuri_id,
      'EXIT_REQUEST',
      'membership_exit',
      new.id,
      jsonb_build_object(
        'exit_id',new.id,
        'membership_id',new.membership_id,
        'reason',new.reason,
        'status',new.status,
        'exit_date',new.exit_date
      ),
      'exit:'||new.id::text||':EXIT_REQUEST',
      v_actor
    );
  elsif tg_op='UPDATE' then
    if new.status is distinct from old.status then
      if new.status='APPROVED' then
        perform public.emit_notification_event_internal(
          v_kuri_id,'EXIT_APPROVAL','membership_exit',new.id,
          jsonb_build_object('exit_id',new.id,'membership_id',new.membership_id,'status',new.status),
          'exit:'||new.id::text||':EXIT_APPROVAL',v_actor
        );
      elsif new.status='SETTLED' then
        perform public.emit_notification_event_internal(
          v_kuri_id,'EXIT_SETTLEMENT','membership_exit',new.id,
          jsonb_build_object('exit_id',new.id,'membership_id',new.membership_id,'status',new.status,'settled_at',new.settled_at),
          'exit:'||new.id::text||':EXIT_SETTLEMENT',v_actor
        );
      end if;
    end if;

    if new.death_date_verified_at is distinct from old.death_date_verified_at
       and new.death_date_verified_at is not null then
      perform public.emit_notification_event_internal(
        v_kuri_id,'DEATH_VERIFICATION','membership_exit',new.id,
        jsonb_build_object(
          'exit_id',new.id,
          'membership_id',new.membership_id,
          'death_date',new.death_date,
          'verified_at',new.death_date_verified_at
        ),
        'exit:'||new.id::text||':DEATH_VERIFICATION',
        new.death_date_verified_by
      );
    end if;
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_exit_notification_event on public.membership_exits;
create trigger emit_exit_notification_event
after insert or update of status,death_date_verified_at on public.membership_exits
for each row execute function public.emit_exit_notification_event();

revoke all on function public.emit_exit_notification_event() from public,anon,authenticated;

create or replace function public.emit_succession_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_kuri_id uuid;
begin
  select m.kuri_id into v_kuri_id
  from public.memberships m
  where m.id=new.membership_id;

  perform public.emit_notification_event_internal(
    v_kuri_id,
    'SUCCESSION',
    'membership_succession',
    new.id,
    jsonb_build_object(
      'succession_id',new.id,
      'membership_id',new.membership_id,
      'membership_exit_id',new.membership_exit_id,
      'original_person_id',new.original_person_id,
      'successor_person_id',new.successor_person_id,
      'nominee_id',new.nominee_id
    ),
    'succession:'||new.id::text||':SUCCESSION',
    new.recorded_by
  );

  return new;
end;
$function$;

drop trigger if exists emit_succession_notification_event on public.membership_successions;
create trigger emit_succession_notification_event
after insert on public.membership_successions
for each row execute function public.emit_succession_notification_event();

revoke all on function public.emit_succession_notification_event() from public,anon,authenticated;

create or replace function public.emit_late_fee_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_event_type text;
  v_key text;
begin
  if tg_op='INSERT' then
    if new.enabled then
      v_event_type:='LATE_FEE_ACTIVATED';
      v_key:='late-fee-rule:'||new.id::text||':ACTIVATED';
    else
      return new;
    end if;
  elsif tg_op='UPDATE' then
    if new.enabled and not old.enabled then
      v_event_type:='LATE_FEE_ACTIVATED';
    elsif new.enabled or old.enabled then
      v_event_type:='LATE_FEE_CHANGED';
    else
      return new;
    end if;
    v_key:='late-fee-rule:'||new.id::text||':'||v_event_type||':'||new.updated_at::text;
  else
    return new;
  end if;

  perform public.emit_notification_event_internal(
    new.kuri_id,
    v_event_type,
    'kuri_late_fee_rule',
    new.id,
    jsonb_build_object(
      'late_fee_rule_id',new.id,
      'enabled',new.enabled,
      'fee_type',new.fee_type,
      'fixed_amount',new.fixed_amount,
      'percentage_basis_points',new.percentage_basis_points,
      'grace_period_days',new.grace_period_days,
      'effective_from',new.effective_from,
      'effective_to',new.effective_to
    ),
    v_key,
    new.created_by
  );

  return new;
end;
$function$;

drop trigger if exists emit_late_fee_notification_event on public.kuri_late_fee_rules;
create trigger emit_late_fee_notification_event
after insert or update on public.kuri_late_fee_rules
for each row execute function public.emit_late_fee_notification_event();

revoke all on function public.emit_late_fee_notification_event() from public,anon,authenticated;

commit;