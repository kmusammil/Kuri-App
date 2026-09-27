-- Notification policy reconciliation v1
-- Align late-payment timing with the canonical notification matrix:
-- emit/resolve the alert at the preferred +1 day opportunity when the
-- installment remains unpaid. Event production remains a separate concern.

update public.notification_event_policies
set timing_kind = 'SCHEDULED',
    reminder_offsets_days = array[1]::integer[],
    updated_at = now()
where event_type = 'LATE_PAYMENT_ALERT';
