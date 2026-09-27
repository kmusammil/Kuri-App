-- Notification dispatcher policy enforcement v1
-- Replaces hard-coded recipient selection with the notification_event_policies
-- registry. Recipient eligibility is resolved to User IDs, scoped to the
-- event's organization/Kuri/membership, deduplicated, and actor-filtered.
-- Delivery remains IN_APP-first; channels come from policy.default_channels.

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
    select
      ne.*,
      nep.actor_policy,
      nep.no_user_policy,
      nep.recipient_rules,
      nep.default_channels
    from public.notification_events ne
    join public.notification_event_policies nep
      on nep.event_type = ne.event_type
     and nep.enabled
    where not exists (
      select 1
      from public.notifications n
      where n.event_id = ne.id
    )
    order by ne.created_at, ne.id
    limit batch_size
  ),
  audience_rules as (
    select
      pe.id as event_id,
      pe.organization_id,
      pe.kuri_id,
      pe.actor_user_id,
      pe.event_type,
      pe.payload,
      pe.actor_policy,
      pe.no_user_policy,
      pe.default_channels,
      ar->>'type' as audience_type,
      ar->>'scope' as audience_scope
    from pending_events pe
    cross join lateral jsonb_array_elements(
      coalesce(pe.recipient_rules->'audiences', '[]'::jsonb)
    ) ar
  ),
  recipient_users as (
    -- Organization MAIN_ADMIN audience.
    select
      a.event_id,
      a.organization_id,
      ou.user_id as recipient_user_id,
      a.default_channels
    from audience_rules a
    join public.organization_users ou
      on ou.organization_id = a.organization_id
     and ou.role = 'MAIN_ADMIN'::public.app_role
    where a.audience_type = 'MAIN_ADMIN'
      and a.audience_scope = 'ORGANIZATION'

    union all

    -- Organization ADMIN audience.
    select
      a.event_id,
      a.organization_id,
      ou.user_id,
      a.default_channels
    from audience_rules a
    join public.organization_users ou
      on ou.organization_id = a.organization_id
     and ou.role = 'ADMIN'::public.app_role
    where a.audience_type = 'ADMIN'
      and a.audience_scope = 'ORGANIZATION'

    union all

    -- Kuri-scoped ADMIN audience.
    select
      a.event_id,
      a.organization_id,
      ka.user_id,
      a.default_channels
    from audience_rules a
    join public.kuri_admins ka
      on ka.kuri_id = a.kuri_id
     and ka.role = 'ADMIN'::public.kuri_admin_role
    where a.audience_type = 'ADMIN'
      and a.audience_scope = 'KURI'

    union all

    -- Kuri members: only active memberships with a linked User account.
    select
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.memberships m
      on m.kuri_id = a.kuri_id
     and m.status = 'ACTIVE'::public.membership_status
    join public.users u
      on u.person_id = m.person_id
    where a.audience_type = 'KURI_MEMBER'
      and a.audience_scope = 'KURI'

    union all

    -- Member with an outstanding installment. The event may identify the
    -- membership directly or identify its installment.
    select distinct
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.installments i
      on (
        i.membership_id = nullif(a.payload->>'membership_id','')::uuid
        or i.id = nullif(a.payload->>'installment_id','')::uuid
      )
    join public.memberships m
      on m.id = i.membership_id
     and m.kuri_id = a.kuri_id
     and m.status = 'ACTIVE'::public.membership_status
    join public.users u
      on u.person_id = m.person_id
    where a.audience_type = 'KURI_MEMBER'
      and a.audience_scope = 'MEMBERSHIP_WITH_OUTSTANDING_INSTALLMENT'
      and i.amount_due > i.amount_paid

    union all

    -- Member with an unpaid installment after its due date.
    select distinct
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.installments i
      on (
        i.membership_id = nullif(a.payload->>'membership_id','')::uuid
        or i.id = nullif(a.payload->>'installment_id','')::uuid
      )
    join public.memberships m
      on m.id = i.membership_id
     and m.kuri_id = a.kuri_id
     and m.status = 'ACTIVE'::public.membership_status
    join public.users u
      on u.person_id = m.person_id
    where a.audience_type = 'KURI_MEMBER'
      and a.audience_scope = 'MEMBERSHIP_WITH_UNPAID_INSTALLMENT'
      and i.amount_due > i.amount_paid
      and i.due_date < current_date

    union all

    -- Winner identified by event payload person_id.
    select
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.users u
      on u.person_id = nullif(a.payload->>'person_id','')::uuid
    where a.audience_type = 'WINNER'
      and a.audience_scope = 'CYCLE'

    union all

    -- Winner identified through a payout's monthly winner.
    select
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.payouts p
      on p.id = nullif(a.payload->>'payout_id','')::uuid
    join public.monthly_winners mw
      on mw.id = p.monthly_winner_id
    join public.users u
      on u.person_id = mw.person_id
    where a.audience_type = 'WINNER'
      and a.audience_scope = 'PAYOUT'

    union all

    -- Current holder for an exit event.
    select
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.membership_exits me
      on me.id = nullif(a.payload->>'exit_id','')::uuid
    join public.memberships m
      on m.id = me.membership_id
     and m.kuri_id = a.kuri_id
    join public.users u
      on u.person_id = m.current_holder_person_id
    where a.audience_type = 'CURRENT_HOLDER'
      and a.audience_scope = 'MEMBERSHIP'

    union all

    -- Current holder when the event identifies the membership directly.
    select
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.memberships m
      on m.id = nullif(a.payload->>'membership_id','')::uuid
     and m.kuri_id = a.kuri_id
    join public.users u
      on u.person_id = m.current_holder_person_id
    where a.audience_type = 'CURRENT_HOLDER'
      and a.audience_scope = 'MEMBERSHIP'

    union all

    -- Successor identified by event payload.
    select
      a.event_id,
      a.organization_id,
      u.id,
      a.default_channels
    from audience_rules a
    join public.users u
      on u.person_id = nullif(a.payload->>'successor_person_id','')::uuid
    where a.audience_type = 'SUCCESSOR'
      and a.audience_scope = 'MEMBERSHIP'
  ),
  deduplicated_recipients as (
    select distinct
      ru.event_id,
      ru.organization_id,
      ru.recipient_user_id,
      channel
    from recipient_users ru
    cross join lateral unnest(ru.default_channels) channel
    where channel = any(array['IN_APP','PUSH','EMAIL','SMS']::text[])
      and not (
        exists (
          select 1
          from pending_events pe
          where pe.id = ru.event_id
            and pe.actor_policy = 'EXCLUDE'
            and pe.actor_user_id = ru.recipient_user_id
        )
      )
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
      case pe.event_type
        when 'DRAW_PREPARATION' then 'Draw preparation required'
        when 'DRAW_RESULT' then 'Draw result finalized'
        when 'WINNER_NOTIFICATION' then 'Winner notification'
        when 'PAYOUT_NOTIFICATION' then 'Payout update'
        when 'EXIT_REQUEST' then 'Membership exit requested'
        when 'EXIT_APPROVAL' then 'Membership exit approved'
        when 'EXIT_SETTLEMENT' then 'Membership exit settled'
        when 'DEATH_REPORT' then 'Death report recorded'
        when 'DEATH_VERIFICATION' then 'Death verification recorded'
        when 'SUCCESSION' then 'Membership succession recorded'
        when 'LATE_FEE_ACTIVATED' then 'Late fee activated'
        when 'LATE_FEE_CHANGED' then 'Late fee configuration changed'
        when 'JOIN_REQUEST' then 'Join request received'
        when 'ADMIN_POSITION_REQUEST' then 'Admin position request received'
        when 'KURI_SCHEDULE_CHANGED' then 'Kuri schedule changed'
        when 'KURI_ANNOUNCEMENT' then 'Kuri announcement'
        when 'PAYMENT_REMINDER' then 'Payment reminder'
        when 'LATE_PAYMENT_ALERT' then 'Late payment alert'
        else replace(initcap(lower(replace(pe.event_type, '_', ' '))), 'Notification', '')
      end,
      case pe.event_type
        when 'DRAW_PREPARATION' then 'A cycle has reached draw preparation.'
        when 'DRAW_RESULT' then 'A draw result has been finalized.'
        when 'WINNER_NOTIFICATION' then 'A winner has been finalized.'
        when 'PAYOUT_NOTIFICATION' then 'A payout status has changed.'
        when 'EXIT_REQUEST' then 'A membership exit request was recorded.'
        when 'EXIT_APPROVAL' then 'A membership exit was approved.'
        when 'EXIT_SETTLEMENT' then 'A membership exit was settled.'
        when 'DEATH_REPORT' then 'A death report was recorded.'
        when 'DEATH_VERIFICATION' then 'A death date was verified for a membership exit.'
        when 'SUCCESSION' then 'A membership succession was recorded.'
        when 'LATE_FEE_ACTIVATED' then 'A late-fee rule was activated.'
        when 'LATE_FEE_CHANGED' then 'A late-fee rule was changed.'
        when 'JOIN_REQUEST' then 'A join request requires review.'
        when 'ADMIN_POSITION_REQUEST' then 'An admin position request requires review.'
        when 'KURI_SCHEDULE_CHANGED' then 'The Kuri schedule has changed.'
        when 'KURI_ANNOUNCEMENT' then 'A new Kuri announcement is available.'
        when 'PAYMENT_REMINDER' then 'An installment payment is due or approaching.'
        when 'LATE_PAYMENT_ALERT' then 'An installment remains unpaid after its due date.'
        else 'A Kuri event requires your attention.'
      end,
      coalesce(pe.payload, '{}'::jsonb),
      now(),
      now(),
      now(),
      0
    from deduplicated_recipients r
    join pending_events pe on pe.id = r.event_id
    on conflict (event_id, recipient_user_id, channel) do nothing
    returning id
  )
  select count(*) into v_inserted from inserted;

  return v_inserted;
end;
$function$;

revoke all on function public.dispatch_notification_events_for_delivery(integer)
  from public, anon, authenticated;
