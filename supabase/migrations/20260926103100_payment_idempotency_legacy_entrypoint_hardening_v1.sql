-- PAYMENT-003 hardening: retire pre-idempotency request entrypoints
revoke execute on function public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text) from authenticated;
revoke execute on function public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text) from authenticated;

grant execute on function public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text,text) to authenticated;
grant execute on function public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text,text) to authenticated;
