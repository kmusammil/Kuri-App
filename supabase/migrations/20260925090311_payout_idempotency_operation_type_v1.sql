BEGIN;

ALTER TABLE public.financial_idempotency_keys
  DROP CONSTRAINT financial_idempotency_keys_operation_type_check;

ALTER TABLE public.financial_idempotency_keys
  ADD CONSTRAINT financial_idempotency_keys_operation_type_check
  CHECK (
    operation_type = ANY (
      ARRAY[
        'PAYMENT_CREATE'::text,
        'PAYMENT_ALLOCATION'::text,
        'PAYOUT_PAYMENT'::text
      ]
    )
  );

COMMIT;