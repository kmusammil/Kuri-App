BEGIN;

ALTER TABLE public.financial_idempotency_keys
  DROP CONSTRAINT financial_idempotency_keys_check;

ALTER TABLE public.financial_idempotency_keys
  ADD CONSTRAINT financial_idempotency_keys_check
  CHECK (
    status = 'IN_PROGRESS'
    OR (
      operation_type IN ('PAYMENT_CREATE','PAYOUT_PAYMENT')
      AND result_payment_id IS NOT NULL
      AND result_bigint IS NULL
      AND completed_at IS NOT NULL
    )
    OR (
      operation_type IN ('PAYMENT_ALLOCATION','DRAW_RUN','DRAW_FINALIZE')
      AND result_payment_id IS NULL
      AND result_bigint IS NOT NULL
      AND completed_at IS NOT NULL
    )
  );

COMMIT;
