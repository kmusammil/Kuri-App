-- Notification automation checkpoint 1: durable event fan-out to in-app recipients.
-- No external email/SMS/push provider is invoked here.

create extension if not exists pg_cron with schema pg_catalog;

create or replace function public.dispatch_notification_events_for_delivery(
  batch_size integer default 200
)
returns integer
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_inserted integer := 0;
begin
  if batch_size is null or batch_size < 1 or batch_size > 1000 then
    raise exception 'batch_size must be between 1 and 1000';
  end if;

  with pending_events as (
    select ne.*
    from public.notification_events ne
    where not exists (
      select 1
      from public.notifications n
      where n.event_id = ne.id
    )
    order by ne.created_at, ne.id
    limit batch_size
  ),
  admin_recipients as (
    select
      pe.id as event_id,
      pe.organization_id,
      ou.user_id as recipient_user_id,
      'IN_APP'::text as channel,
      pe.event_type,
      pe.payload
    from pending_events pe
    join public.organization_users ou
      on ou.organization_id = pe.organization_id
     and ou.role in ('MAIN_ADMIN','ADMIN')
  ),
  member_recipients as (
    select distinct
      pe.id as event_id,
      pe.organization_id,
      u.id as recipient_user_id,
      'IN_APP'::text as channel,
      pe.event_type,
      pe.payload
    from pending_events pe
    join public.users u
      on u.id = case
        when pe.event_type in ('WINNER_NOTIFICATION','DRAW_RESULT')
          then nullif(pe.payload->>'person_id','')::uuid
        when pe.event_type = 'PAYOUT_NOTIFICATION'
          then (
            select p.person_id
            from public.monthly_winners mw
            join public.payouts p on p.monthly_winner_id = mw.id
            where mw.id = nullif(pe.payload->>'winner_id','')::uuid
            limit 1
          )
        when pe.event_type in ('EXIT_REQUEST','EXIT_APPROVAL','EXIT_SETTLEMENT','DEATH_VERIFICATION')
          then (
            select m.current_holder_person_id
            from public.membership_exits me
            join public.memberships m on m.id = me.membership_id
            where me.id = nullif(pe.payload->>'exit_id','')::uuid
            limit 1
          )
        when pe.event_type = 'SUCCESSION'
          then nullif(pe.payload->>'successor_person_id','')::uuid
        else null
      end
    where u.person_id is not null
  ),
  recipients as (
    select * from admin_recipients
    union
    select * from member_recipients
  ),
  inserted as (
    insert into public.notifications (
      event_id,
      organization_id,
      recipient_user_id,
      channel,
      status,
      title,
      body,
      data,
      created_at,
      queued_at,
      sent_at,
      attempt_count
    )
    select
      r.event_id,
      r.organization_id,
      r.recipient_user_id,
      r.channel,
      'SENT',
      case r.event_type
        when 'DRAW_PREPARATION' then 'Draw preparation required'
        when 'DRAW_RESULT' then 'Draw result finalized'
        when 'WINNER_NOTIFICATION' then 'Winner notification'
        when 'PAYOUT_NOTIFICATION' then 'Payout update'
        when 'EXIT_REQUEST' then 'Membership exit requested'
        when 'EXIT_APPROVAL' then 'Membership exit approved'
        when 'EXIT_SETTLEMENT' then 'Membership exit settled'
        when 'DEATH_VERIFICATION' then 'Death verification recorded'
        when 'SUCCESSION' then 'Membership succession recorded'
        when 'LATE_FEE_ACTIVATED' then 'Late fee activated'
        when 'LATE_FEE_CHANGED' then 'Late fee configuration changed'
        else replace(initcap(lower(replace(r.event_type, '_', ' '))), 'Notification', '')
      end,
      case r.event_type
        when 'DRAW_PREPARATION' then 'A cycle has reached draw preparation.'
        when 'DRAW_RESULT' then 'A draw result has been finalized.'
        when 'WINNER_NOTIFICATION' then 'A winner has been finalized.'
        when 'PAYOUT_NOTIFICATION' then 'A payout status has changed.'
        when 'EXIT_REQUEST' then 'A membership exit request was recorded.'
        when 'EXIT_APPROVAL' then 'A membership exit was approved.'
        when 'EXIT_SETTLEMENT' then 'A membership exit was settled.'
        when 'DEATH_VERIFICATION' then 'A death date was verified for a membership exit.'
        when 'SUCCESSION' then 'A membership succession was recorded.'
        when 'LATE_FEE_ACTIVATED' then 'A late-fee rule was activated.'
        when 'LATE_FEE_CHANGED' then 'A late-fee rule was changed.'
        else 'A Kuri event requires your attention.'
      end,
      coalesce(r.payload, '{}'::jsonb),
      now(),
      now(),
      now(),
      0
    from recipients r
    on conflict (event_id, recipient_user_id, channel) do nothing
    returning id
  )
  select count(*) into v_inserted from inserted;

  return v_inserted;
end;
$function$;

revoke all on function public.dispatch_notification_events_for_delivery(integer) from public, anon, authenticated;

select cron.schedule(
  'kuri-notification-event-dispatch',
  '* * * * *',
  $$select public.dispatch_notification_events_for_delivery(200);$$
);
