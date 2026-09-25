-- Contract cleanup: the canonical exit/death mutation APIs require explicit idempotency keys.
-- The workflow definitions are established by the preceding reconciliation migration; this migration
-- removes any legacy short overloads that must not remain exposed.
DROP FUNCTION IF EXISTS public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text);
DROP FUNCTION IF EXISTS public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz);
DROP FUNCTION IF EXISTS public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text);
DROP FUNCTION IF EXISTS public.record_death_settlement_for_admin(uuid,uuid,text);