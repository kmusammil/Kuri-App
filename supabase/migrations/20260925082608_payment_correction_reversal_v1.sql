DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='payment_adjustment_type'
  ) THEN
    CREATE TYPE public.payment_adjustment_type AS ENUM ('CORRECTION','REVERSAL');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname='public' AND t.typname='payment_adjustment_status'
  ) THEN
    CREATE TYPE public.payment_adjustment_status AS ENUM ('REQUESTED','APPROVED','EXECUTED','REJECTED');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.payment_adjustment_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kuri_id uuid NOT NULL,
  payment_id uuid NOT NULL REFERENCES public.payments(id) ON DELETE RESTRICT,
  adjustment_type public.payment_adjustment_type NOT NULL,
  status public.payment_adjustment_status NOT NULL DEFAULT 'REQUESTED',
  requested_amount bigint,
  target_allocation_id uuid REFERENCES public.payment_allocations(id) ON DELETE RESTRICT,
  base_correction_id uuid,
  corrected_amount bigint,
  corrected_payment_date timestamptz,
  corrected_method public.payment_method,
  corrected_reference_number text,
  corrected_proof_file_id uuid REFERENCES public.files(id) ON DELETE SET NULL,
  corrected_notes text,
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 1 AND 2000),
  rejection_reason text CHECK (rejection_reason IS NULL OR char_length(btrim(rejection_reason)) BETWEEN 1 AND 2000),
  requested_by uuid NOT NULL REFERENCES public.users(id) ON DELETE RESTRICT,
  requested_at timestamptz NOT NULL DEFAULT now(),
  reviewed_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  executed_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  executed_at timestamptz,
  CONSTRAINT payment_adjustment_requests_kuri_org_fkey
    FOREIGN KEY (kuri_id, organization_id) REFERENCES public.kuris(id, organization_id) ON DELETE RESTRICT,
  CHECK (
    (adjustment_type='REVERSAL'
      AND requested_amount IS NOT NULL AND requested_amount>0
      AND corrected_amount IS NULL AND corrected_payment_date IS NULL
      AND corrected_method IS NULL AND corrected_reference_number IS NULL
      AND corrected_proof_file_id IS NULL AND corrected_notes IS NULL)
    OR
    (adjustment_type='CORRECTION'
      AND requested_amount IS NULL
      AND corrected_amount IS NOT NULL AND corrected_amount>0
      AND corrected_payment_date IS NOT NULL AND corrected_method IS NOT NULL)
  ),
  CHECK (status <> 'REJECTED' OR rejection_reason IS NOT NULL),
  CHECK (status IN ('REQUESTED','APPROVED') OR reviewed_by IS NOT NULL),
  CHECK (status <> 'EXECUTED' OR executed_by IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS payment_adjustment_requests_kuri_status_idx
  ON public.payment_adjustment_requests(kuri_id,status,requested_at DESC);
CREATE INDEX IF NOT EXISTS payment_adjustment_requests_payment_idx
  ON public.payment_adjustment_requests(payment_id,requested_at DESC);
CREATE INDEX IF NOT EXISTS payment_adjustment_requests_target_allocation_idx
  ON public.payment_adjustment_requests(target_allocation_id)
  WHERE target_allocation_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.payment_corrections (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL UNIQUE REFERENCES public.payment_adjustment_requests(id) ON DELETE RESTRICT,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kuri_id uuid NOT NULL,
  payment_id uuid NOT NULL REFERENCES public.payments(id) ON DELETE RESTRICT,
  previous_amount bigint NOT NULL CHECK (previous_amount>0),
  previous_payment_date timestamptz NOT NULL,
  previous_method public.payment_method NOT NULL,
  previous_reference_number text,
  previous_proof_file_id uuid REFERENCES public.files(id) ON DELETE SET NULL,
  previous_notes text,
  corrected_amount bigint NOT NULL CHECK (corrected_amount>0),
  corrected_payment_date timestamptz NOT NULL,
  corrected_method public.payment_method NOT NULL,
  corrected_reference_number text,
  corrected_proof_file_id uuid REFERENCES public.files(id) ON DELETE SET NULL,
  corrected_notes text,
  applied_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payment_corrections_kuri_org_fkey
    FOREIGN KEY (kuri_id, organization_id) REFERENCES public.kuris(id, organization_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS payment_corrections_payment_idx
  ON public.payment_corrections(payment_id,applied_at DESC);

CREATE TABLE IF NOT EXISTS public.payment_reversal_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.payment_adjustment_requests(id) ON DELETE RESTRICT,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
  kuri_id uuid NOT NULL,
  payment_id uuid NOT NULL REFERENCES public.payments(id) ON DELETE RESTRICT,
  allocation_id uuid REFERENCES public.payment_allocations(id) ON DELETE RESTRICT,
  amount bigint NOT NULL CHECK (amount>0),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payment_reversal_entries_kuri_org_fkey
    FOREIGN KEY (kuri_id, organization_id) REFERENCES public.kuris(id, organization_id) ON DELETE RESTRICT,
  UNIQUE(request_id,allocation_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS payment_reversal_entries_one_unallocated_per_request
  ON public.payment_reversal_entries(request_id) WHERE allocation_id IS NULL;
CREATE INDEX IF NOT EXISTS payment_reversal_entries_payment_idx
  ON public.payment_reversal_entries(payment_id,created_at DESC);
CREATE INDEX IF NOT EXISTS payment_reversal_entries_allocation_idx
  ON public.payment_reversal_entries(allocation_id,created_at DESC)
  WHERE allocation_id IS NOT NULL;

ALTER TABLE public.payment_adjustment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_corrections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_reversal_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_adjustment_requests FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.payment_corrections FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.payment_reversal_entries FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_effective_payment_amount(target_payment_id uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT greatest(
    coalesce((
      SELECT pc.corrected_amount FROM public.payment_corrections pc
      WHERE pc.payment_id=target_payment_id
      ORDER BY pc.applied_at DESC,pc.id DESC LIMIT 1
    ),p.amount)
    - coalesce((SELECT sum(pr.amount) FROM public.payment_reversal_entries pr WHERE pr.payment_id=target_payment_id),0),
    0
  )
  FROM public.payments p WHERE p.id=target_payment_id;
$$;

CREATE OR REPLACE FUNCTION public.get_effective_payment_allocation_amount(target_allocation_id uuid)
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT greatest(
    pa.amount - coalesce((
      SELECT sum(pr.amount) FROM public.payment_reversal_entries pr
      WHERE pr.allocation_id=target_allocation_id
    ),0),
    0
  )
  FROM public.payment_allocations pa WHERE pa.id=target_allocation_id;
$$;

REVOKE ALL ON FUNCTION public.get_effective_payment_amount(uuid) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.get_effective_payment_allocation_amount(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.reconcile_installment_from_allocations(target_installment_id uuid)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  target_amount_due bigint;
  allocated_total bigint;
  target_kuri_id uuid;
  target_amount_paid bigint;
  prior_status public.installment_status;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT i.amount_due,k.id,i.status INTO target_amount_due,target_kuri_id,prior_status
  FROM public.installments i
  JOIN public.memberships m ON m.id=i.membership_id
  JOIN public.kuris k ON k.id=m.kuri_id
  WHERE i.id=target_installment_id FOR UPDATE;
  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Installment not found.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to reconcile this installment.';
  END IF;
  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) INTO allocated_total
  FROM public.payment_allocations pa WHERE pa.installment_id=target_installment_id;
  target_amount_paid:=least(greatest(allocated_total,0),target_amount_due);
  UPDATE public.installments
  SET amount_paid=target_amount_paid,
      status=case
        when target_amount_paid>=amount_due then
          case when prior_status='PAID_LATE' then 'PAID_LATE'::public.installment_status else 'PAID'::public.installment_status end
        when target_amount_paid>0 then 'PARTIAL'::public.installment_status
        else 'UNPAID'::public.installment_status
      end,
      updated_at=now()
  WHERE id=target_installment_id;
  RETURN target_amount_paid;
END;
$$;
REVOKE ALL ON FUNCTION public.reconcile_installment_from_allocations(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.create_payment_correction_request_for_admin(
  target_payment_id uuid, corrected_amount bigint, corrected_payment_date timestamptz,
  corrected_method public.payment_method, corrected_reference_number text,
  corrected_proof_file_id uuid, corrected_notes text, reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  actor_user_id uuid := (select auth.uid());
  payment_kuri_id uuid; payment_org_id uuid; payment_status public.payment_status;
  current_amount bigint; current_payment_date timestamptz;
  current_method public.payment_method; current_reference text; current_proof uuid; current_notes text;
  latest_correction_id uuid; request_id uuid;
BEGIN
  IF actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF corrected_amount<=0 THEN RAISE EXCEPTION 'Corrected payment amount must be greater than zero.'; END IF;
  IF nullif(btrim(reason),'') IS NULL THEN RAISE EXCEPTION 'A reason is required.'; END IF;
  SELECT p.kuri_id,p.organization_id,p.status,p.amount,p.payment_date,p.method,p.reference_number,p.proof_file_id,p.notes
    INTO payment_kuri_id,payment_org_id,payment_status,current_amount,current_payment_date,current_method,current_reference,current_proof,current_notes
  FROM public.payments p WHERE p.id=target_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  IF payment_status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be corrected.'; END IF;
  IF NOT public.has_kuri_admin_role(payment_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to correct this payment.';
  END IF;
  IF corrected_proof_file_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.files f WHERE f.id=corrected_proof_file_id AND f.organization_id=payment_org_id
  ) THEN RAISE EXCEPTION 'Proof file does not belong to this organization.'; END IF;
  SELECT pc.id,pc.corrected_amount,pc.corrected_payment_date,pc.corrected_method,
         pc.corrected_reference_number,pc.corrected_proof_file_id,pc.corrected_notes
    INTO latest_correction_id,current_amount,current_payment_date,current_method,current_reference,current_proof,current_notes
  FROM public.payment_corrections pc
  WHERE pc.payment_id=target_payment_id ORDER BY pc.applied_at DESC,pc.id DESC LIMIT 1;
  IF corrected_amount=current_amount AND corrected_payment_date=current_payment_date
     AND corrected_method=current_method
     AND corrected_reference_number IS NOT DISTINCT FROM current_reference
     AND corrected_proof_file_id IS NOT DISTINCT FROM current_proof
     AND corrected_notes IS NOT DISTINCT FROM current_notes THEN
    RAISE EXCEPTION 'Correction does not change the recorded payment.';
  END IF;
  IF corrected_amount < coalesce((
    SELECT sum(public.get_effective_payment_allocation_amount(pa.id))
    FROM public.payment_allocations pa WHERE pa.payment_id=target_payment_id
  ),0) THEN
    RAISE EXCEPTION 'Corrected amount cannot be less than the currently allocated amount.';
  END IF;
  INSERT INTO public.payment_adjustment_requests(
    organization_id,kuri_id,payment_id,adjustment_type,status,base_correction_id,
    corrected_amount,corrected_payment_date,corrected_method,corrected_reference_number,
    corrected_proof_file_id,corrected_notes,reason,requested_by
  ) VALUES(
    payment_org_id,payment_kuri_id,target_payment_id,'CORRECTION','REQUESTED',latest_correction_id,
    corrected_amount,corrected_payment_date,corrected_method,nullif(btrim(corrected_reference_number),''),
    corrected_proof_file_id,nullif(btrim(corrected_notes),''),btrim(reason),actor_user_id
  ) RETURNING id INTO request_id;
  INSERT INTO public.audit_logs(organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason)
  VALUES(payment_org_id,actor_user_id,'payment_correction_requested','payment_adjustment_request',
         request_id,NULL,(SELECT to_jsonb(r) FROM public.payment_adjustment_requests r WHERE r.id=request_id),btrim(reason));
  RETURN request_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_payment_reversal_request_for_admin(
  target_payment_id uuid, reversal_amount bigint, target_allocation_id uuid, reason text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  actor_user_id uuid := (select auth.uid());
  payment_kuri_id uuid; payment_org_id uuid; payment_status public.payment_status;
  effective_payment_amount bigint; effective_allocated_total bigint;
  target_allocation_amount bigint; target_allocation_payment_id uuid; request_id uuid;
BEGIN
  IF actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF reversal_amount<=0 THEN RAISE EXCEPTION 'Reversal amount must be greater than zero.'; END IF;
  IF nullif(btrim(reason),'') IS NULL THEN RAISE EXCEPTION 'A reason is required.'; END IF;
  SELECT p.kuri_id,p.organization_id,p.status INTO payment_kuri_id,payment_org_id,payment_status
  FROM public.payments p WHERE p.id=target_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  IF payment_status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be reversed.'; END IF;
  IF NOT public.has_kuri_admin_role(payment_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to reverse this payment.';
  END IF;
  effective_payment_amount:=public.get_effective_payment_amount(target_payment_id);
  IF effective_payment_amount<=0 THEN RAISE EXCEPTION 'Payment is already fully reversed.'; END IF;
  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    INTO effective_allocated_total
  FROM public.payment_allocations pa WHERE pa.payment_id=target_payment_id;
  IF target_allocation_id IS NOT NULL THEN
    SELECT pa.payment_id,public.get_effective_payment_allocation_amount(pa.id)
      INTO target_allocation_payment_id,target_allocation_amount
    FROM public.payment_allocations pa WHERE pa.id=target_allocation_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Allocation not found.'; END IF;
    IF target_allocation_payment_id<>target_payment_id THEN RAISE EXCEPTION 'Target allocation does not belong to this payment.'; END IF;
    IF target_allocation_amount<=0 THEN RAISE EXCEPTION 'Target allocation is already fully reversed.'; END IF;
    IF reversal_amount>target_allocation_amount THEN
      RAISE EXCEPTION 'Reversal exceeds the allocation amount available to reverse.';
    END IF;
  ELSE
    IF reversal_amount>effective_payment_amount THEN RAISE EXCEPTION 'Reversal exceeds the unreversed payment amount.'; END IF;
    IF effective_allocated_total>0 AND reversal_amount<>effective_payment_amount THEN
      RAISE EXCEPTION 'A partial payment-level reversal with existing allocations requires a target allocation.';
    END IF;
  END IF;
  INSERT INTO public.payment_adjustment_requests(
    organization_id,kuri_id,payment_id,adjustment_type,status,requested_amount,target_allocation_id,reason,requested_by
  ) VALUES(payment_org_id,payment_kuri_id,target_payment_id,'REVERSAL','REQUESTED',reversal_amount,target_allocation_id,btrim(reason),actor_user_id)
  RETURNING id INTO request_id;
  INSERT INTO public.audit_logs(organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason)
  VALUES(payment_org_id,actor_user_id,'payment_reversal_requested','payment_adjustment_request',
         request_id,NULL,(SELECT to_jsonb(r) FROM public.payment_adjustment_requests r WHERE r.id=request_id),btrim(reason));
  RETURN request_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.approve_payment_adjustment_request_for_admin(target_request_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE actor_user_id uuid := (select auth.uid()); request_row public.payment_adjustment_requests%rowtype;
BEGIN
  IF actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT r.* INTO request_row FROM public.payment_adjustment_requests r WHERE r.id=target_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Adjustment request not found.'; END IF;
  IF NOT public.has_kuri_admin_role(request_row.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to approve this adjustment request.';
  END IF;
  IF request_row.status='APPROVED' THEN RETURN; END IF;
  IF request_row.status<>'REQUESTED' THEN RAISE EXCEPTION 'Only REQUESTED adjustment requests can be approved.'; END IF;
  UPDATE public.payment_adjustment_requests SET status='APPROVED',reviewed_by=actor_user_id,reviewed_at=now()
  WHERE id=target_request_id;
  INSERT INTO public.audit_logs(organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason)
  VALUES(request_row.organization_id,actor_user_id,'payment_adjustment_approved','payment_adjustment_request',
         target_request_id,to_jsonb(request_row),
         (SELECT to_jsonb(r) FROM public.payment_adjustment_requests r WHERE r.id=target_request_id),
         request_row.reason);
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_payment_adjustment_request_for_admin(target_request_id uuid,p_rejection_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE actor_user_id uuid := (select auth.uid()); request_row public.payment_adjustment_requests%rowtype;
BEGIN
  IF actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF nullif(btrim(p_rejection_reason),'') IS NULL THEN RAISE EXCEPTION 'A rejection reason is required.'; END IF;
  SELECT r.* INTO request_row FROM public.payment_adjustment_requests r WHERE r.id=target_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Adjustment request not found.'; END IF;
  IF NOT public.has_kuri_admin_role(request_row.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to reject this adjustment request.';
  END IF;
  IF request_row.status='REJECTED' THEN RETURN; END IF;
  IF request_row.status<>'REQUESTED' THEN RAISE EXCEPTION 'Only REQUESTED adjustment requests can be rejected.'; END IF;
  UPDATE public.payment_adjustment_requests
  SET status='REJECTED',rejection_reason=btrim(p_rejection_reason),reviewed_by=actor_user_id,reviewed_at=now()
  WHERE id=target_request_id;
  INSERT INTO public.audit_logs(organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason)
  VALUES(request_row.organization_id,actor_user_id,'payment_adjustment_rejected','payment_adjustment_request',
         target_request_id,to_jsonb(request_row),
         (SELECT to_jsonb(r) FROM public.payment_adjustment_requests r WHERE r.id=target_request_id),
         btrim(p_rejection_reason));
END;
$$;

CREATE OR REPLACE FUNCTION public.execute_payment_adjustment_request_for_admin(target_request_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  actor_user_id uuid := (select auth.uid());
  request_row public.payment_adjustment_requests%rowtype;
  payment_row public.payments%rowtype;
  latest_correction_id uuid;
  current_amount bigint; current_payment_date timestamptz; current_method public.payment_method;
  current_reference text; current_proof uuid; current_notes text;
  effective_allocated_total bigint; reversal_total bigint;
  unallocated_effective bigint; target_allocation_amount bigint; target_installment_id uuid;
  target_allocation_id uuid; effective_payment_amount bigint;
BEGIN
  IF actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT r.* INTO request_row FROM public.payment_adjustment_requests r WHERE r.id=target_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Adjustment request not found.'; END IF;
  IF NOT public.has_kuri_admin_role(request_row.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to execute this adjustment request.';
  END IF;
  IF request_row.status='EXECUTED' THEN RETURN; END IF;
  IF request_row.status<>'APPROVED' THEN RAISE EXCEPTION 'Only APPROVED adjustment requests can be executed.'; END IF;
  SELECT * INTO payment_row FROM public.payments p WHERE p.id=request_row.payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  IF payment_row.status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be adjusted.'; END IF;

  IF request_row.adjustment_type='CORRECTION' THEN
    SELECT pc.id,pc.corrected_amount,pc.corrected_payment_date,pc.corrected_method,
           pc.corrected_reference_number,pc.corrected_proof_file_id,pc.corrected_notes
      INTO latest_correction_id,current_amount,current_payment_date,current_method,current_reference,current_proof,current_notes
    FROM public.payment_corrections pc WHERE pc.payment_id=payment_row.id
    ORDER BY pc.applied_at DESC,pc.id DESC LIMIT 1;
    IF coalesce(latest_correction_id::text,'')<>coalesce(request_row.base_correction_id::text,'') THEN
      RAISE EXCEPTION 'Payment was corrected after this request was created; create a new correction request.';
    END IF;
    IF latest_correction_id IS NULL THEN
      current_amount:=payment_row.amount; current_payment_date:=payment_row.payment_date;
      current_method:=payment_row.method; current_reference:=payment_row.reference_number;
      current_proof:=payment_row.proof_file_id; current_notes:=payment_row.notes;
    END IF;
    SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
      INTO effective_allocated_total
    FROM public.payment_allocations pa WHERE pa.payment_id=payment_row.id;
    SELECT coalesce(sum(pr.amount),0) INTO reversal_total
    FROM public.payment_reversal_entries pr WHERE pr.payment_id=payment_row.id;
    IF request_row.corrected_amount<effective_allocated_total THEN
      RAISE EXCEPTION 'Corrected amount cannot be less than the currently allocated amount.';
    END IF;
    IF request_row.corrected_amount<reversal_total THEN
      RAISE EXCEPTION 'Corrected amount cannot be below already executed reversals.';
    END IF;
    INSERT INTO public.payment_corrections(
      request_id,organization_id,kuri_id,payment_id,
      previous_amount,previous_payment_date,previous_method,previous_reference_number,
      previous_proof_file_id,previous_notes,corrected_amount,corrected_payment_date,
      corrected_method,corrected_reference_number,corrected_proof_file_id,corrected_notes
    ) VALUES(
      request_row.id,payment_row.organization_id,payment_row.kuri_id,payment_row.id,
      current_amount,current_payment_date,current_method,current_reference,current_proof,current_notes,
      request_row.corrected_amount,request_row.corrected_payment_date,request_row.corrected_method,
      request_row.corrected_reference_number,request_row.corrected_proof_file_id,request_row.corrected_notes
    );
  ELSE
    IF request_row.target_allocation_id IS NOT NULL THEN
      SELECT public.get_effective_payment_allocation_amount(pa.id),i.id
        INTO target_allocation_amount,target_installment_id
      FROM public.payment_allocations pa
      JOIN public.installments i ON i.id=pa.installment_id
      WHERE pa.id=request_row.target_allocation_id AND pa.payment_id=payment_row.id
      FOR UPDATE;
      IF target_allocation_amount IS NULL THEN RAISE EXCEPTION 'Target allocation not found for this payment.'; END IF;
      IF target_allocation_amount<=0 THEN RAISE EXCEPTION 'Target allocation is already fully reversed.'; END IF;
      IF request_row.requested_amount>target_allocation_amount THEN
        RAISE EXCEPTION 'Reversal exceeds the allocation amount still available to reverse.';
      END IF;
      INSERT INTO public.payment_reversal_entries(
        request_id,organization_id,kuri_id,payment_id,allocation_id,amount
      ) VALUES(
        request_row.id,payment_row.organization_id,payment_row.kuri_id,payment_row.id,
        request_row.target_allocation_id,request_row.requested_amount
      );
      PERFORM public.reconcile_installment_from_allocations(target_installment_id);
    ELSE
      effective_payment_amount:=public.get_effective_payment_amount(payment_row.id);
      IF effective_payment_amount<=0 THEN RAISE EXCEPTION 'Payment is already fully reversed.'; END IF;
      IF request_row.requested_amount>effective_payment_amount THEN RAISE EXCEPTION 'Reversal exceeds the unreversed payment amount.'; END IF;
      SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
        INTO effective_allocated_total
      FROM public.payment_allocations pa WHERE pa.payment_id=payment_row.id;
      IF effective_allocated_total>0 AND request_row.requested_amount<>effective_payment_amount THEN
        RAISE EXCEPTION 'A partial payment-level reversal with existing allocations requires a target allocation.';
      END IF;
      IF effective_allocated_total>0 THEN
        FOR target_allocation_amount,target_installment_id,target_allocation_id IN
          SELECT public.get_effective_payment_allocation_amount(pa.id),i.id,pa.id
          FROM public.payment_allocations pa
          JOIN public.installments i ON i.id=pa.installment_id
          WHERE pa.payment_id=payment_row.id
            AND public.get_effective_payment_allocation_amount(pa.id)>0
          ORDER BY pa.id
          FOR UPDATE
        LOOP
          INSERT INTO public.payment_reversal_entries(
            request_id,organization_id,kuri_id,payment_id,allocation_id,amount
          ) VALUES(
            request_row.id,payment_row.organization_id,payment_row.kuri_id,payment_row.id,
            target_allocation_id,target_allocation_amount
          );
          PERFORM public.reconcile_installment_from_allocations(target_installment_id);
        END LOOP;
        SELECT public.get_effective_payment_amount(payment_row.id) INTO unallocated_effective;
        IF unallocated_effective>0 THEN
          INSERT INTO public.payment_reversal_entries(
            request_id,organization_id,kuri_id,payment_id,allocation_id,amount
          ) VALUES(
            request_row.id,payment_row.organization_id,payment_row.kuri_id,payment_row.id,NULL,unallocated_effective
          );
        END IF;
      ELSE
        INSERT INTO public.payment_reversal_entries(
          request_id,organization_id,kuri_id,payment_id,allocation_id,amount
        ) VALUES(
          request_row.id,payment_row.organization_id,payment_row.kuri_id,payment_row.id,NULL,request_row.requested_amount
        );
      END IF;
    END IF;
  END IF;

  UPDATE public.payment_adjustment_requests
  SET status='EXECUTED',executed_by=actor_user_id,executed_at=now()
  WHERE id=target_request_id;

  INSERT INTO public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  VALUES(
    request_row.organization_id,actor_user_id,
    case when request_row.adjustment_type='CORRECTION' then 'payment_correction_executed' else 'payment_reversal_executed' end,
    'payment_adjustment_request',target_request_id,to_jsonb(request_row),
    jsonb_build_object(
      'request',(SELECT to_jsonb(r) FROM public.payment_adjustment_requests r WHERE r.id=target_request_id),
      'corrections',coalesce((
        SELECT jsonb_agg(to_jsonb(pc) order by pc.applied_at,pc.id)
        FROM public.payment_corrections pc WHERE pc.request_id=target_request_id
      ),'[]'::jsonb),
      'reversals',coalesce((
        SELECT jsonb_agg(to_jsonb(pr) order by pr.created_at,pr.id)
        FROM public.payment_reversal_entries pr WHERE pr.request_id=target_request_id
      ),'[]'::jsonb)
    ),
    request_row.reason
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_payment_adjustment_requests_for_admin(target_kuri_id uuid)
RETURNS TABLE(
  id uuid,payment_id uuid,adjustment_type public.payment_adjustment_type,
  status public.payment_adjustment_status,requested_amount bigint,target_allocation_id uuid,
  base_correction_id uuid,corrected_amount bigint,corrected_payment_date timestamptz,
  corrected_method public.payment_method,corrected_reference_number text,
  corrected_proof_file_id uuid,corrected_notes text,reason text,rejection_reason text,
  requested_by uuid,requested_at timestamptz,reviewed_by uuid,reviewed_at timestamptz,
  executed_by uuid,executed_at timestamptz
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT r.id,r.payment_id,r.adjustment_type,r.status,r.requested_amount,r.target_allocation_id,
         r.base_correction_id,r.corrected_amount,r.corrected_payment_date,r.corrected_method,
         r.corrected_reference_number,r.corrected_proof_file_id,r.corrected_notes,r.reason,
         r.rejection_reason,r.requested_by,r.requested_at,r.reviewed_by,r.reviewed_at,
         r.executed_by,r.executed_at
  FROM public.payment_adjustment_requests r
  WHERE r.kuri_id=target_kuri_id
    AND public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY r.requested_at DESC,r.id DESC;
$$;

CREATE OR REPLACE FUNCTION public.get_payment_adjustment_request_for_admin(target_request_id uuid)
RETURNS TABLE(
  id uuid,payment_id uuid,kuri_id uuid,adjustment_type public.payment_adjustment_type,
  status public.payment_adjustment_status,requested_amount bigint,target_allocation_id uuid,
  base_correction_id uuid,corrected_amount bigint,corrected_payment_date timestamptz,
  corrected_method public.payment_method,corrected_reference_number text,
  corrected_proof_file_id uuid,corrected_notes text,reason text,rejection_reason text,
  requested_by uuid,requested_at timestamptz,reviewed_by uuid,reviewed_at timestamptz,
  executed_by uuid,executed_at timestamptz
) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT r.id,r.payment_id,r.kuri_id,r.adjustment_type,r.status,r.requested_amount,r.target_allocation_id,
         r.base_correction_id,r.corrected_amount,r.corrected_payment_date,r.corrected_method,
         r.corrected_reference_number,r.corrected_proof_file_id,r.corrected_notes,r.reason,
         r.rejection_reason,r.requested_by,r.requested_at,r.reviewed_by,r.reviewed_at,
         r.executed_by,r.executed_at
  FROM public.payment_adjustment_requests r
  WHERE r.id=target_request_id
    AND public.has_kuri_admin_role(r.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$$;

REVOKE ALL ON FUNCTION public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.approve_payment_adjustment_request_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.reject_payment_adjustment_request_for_admin(uuid,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.execute_payment_adjustment_request_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_payment_adjustment_requests_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_payment_adjustment_request_for_admin(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_payment_adjustment_request_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_payment_adjustment_request_for_admin(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.execute_payment_adjustment_request_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_payment_adjustment_requests_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_payment_adjustment_request_for_admin(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_payment_for_admin(target_payment_id uuid)
RETURNS TABLE(id uuid,person_id uuid,registered_name text,display_name text,amount bigint,payment_date timestamptz,method public.payment_method,reference_number text,status public.payment_status,notes text,submitted_at timestamptz,verified_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT p.id,p.person_id,pe.registered_name,pe.display_name,public.get_effective_payment_amount(p.id),
         coalesce(pc.corrected_payment_date,p.payment_date),coalesce(pc.corrected_method,p.method),
         case when pc.id is null then p.reference_number else pc.corrected_reference_number end,p.status,
         case when pc.id is null then p.notes else pc.corrected_notes end,p.submitted_at,p.verified_at
  FROM public.payments p
  JOIN public.people pe ON pe.id=p.person_id
  LEFT JOIN LATERAL (
    SELECT pc.* FROM public.payment_corrections pc WHERE pc.payment_id=p.id
    ORDER BY pc.applied_at DESC,pc.id DESC LIMIT 1
  ) pc ON true
  WHERE p.id=target_payment_id
    AND public.has_kuri_admin_role(p.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$$;

CREATE OR REPLACE FUNCTION public.list_payments_for_admin(target_kuri_id uuid)
RETURNS TABLE(id uuid,person_id uuid,registered_name text,display_name text,amount bigint,payment_date timestamptz,method public.payment_method,reference_number text,status public.payment_status)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT p.id,p.person_id,pe.registered_name,pe.display_name,public.get_effective_payment_amount(p.id),
         coalesce(pc.corrected_payment_date,p.payment_date),coalesce(pc.corrected_method,p.method),
         case when pc.id is null then p.reference_number else pc.corrected_reference_number end,p.status
  FROM public.payments p
  JOIN public.people pe ON pe.id=p.person_id
  LEFT JOIN LATERAL (
    SELECT pc.* FROM public.payment_corrections pc WHERE pc.payment_id=p.id
    ORDER BY pc.applied_at DESC,pc.id DESC LIMIT 1
  ) pc ON true
  WHERE p.kuri_id=target_kuri_id
    AND public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY p.payment_date DESC,p.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.list_payment_allocations_for_admin(target_payment_id uuid)
RETURNS TABLE(id uuid,installment_id uuid,kuri_id uuid,kuri_name text,cycle_number integer,membership_number text,amount bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public
AS $$
  SELECT pa.id,i.id,k.id,k.name,c.cycle_number,m.membership_number,
         public.get_effective_payment_allocation_amount(pa.id)
  FROM public.payment_allocations pa
  JOIN public.payments p ON p.id=pa.payment_id
  JOIN public.installments i ON i.id=pa.installment_id
  JOIN public.memberships m ON m.id=i.membership_id
  JOIN public.cycles c ON c.id=i.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE pa.payment_id=target_payment_id AND p.kuri_id=k.id
    AND public.has_kuri_admin_role(k.id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY c.cycle_number,m.membership_number;
$$;

DROP FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint,text);
CREATE FUNCTION public.allocate_payment_for_admin(target_payment_id uuid,target_installment_id uuid,allocation_amount bigint,p_idempotency_key text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE
  v_actor_user_id uuid := (select auth.uid()); normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text; idem_row public.financial_idempotency_keys%rowtype;
  payment_person_id uuid; payment_total bigint; payment_status public.payment_status; payment_kuri_id uuid;
  installment_person_id uuid; installment_amount_due bigint; target_kuri_id uuid; already_allocated bigint;
  installment_allocated bigint; next_paid bigint;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF allocation_amount<=0 THEN RAISE EXCEPTION 'Allocation amount must be greater than zero.'; END IF;
  request_hash:=encode(extensions.digest(jsonb_build_array(target_payment_id::text,target_installment_id::text,allocation_amount::text)::text,'sha256'),'hex');
  SELECT p.person_id,p.status,p.kuri_id INTO payment_person_id,payment_status,payment_kuri_id
  FROM public.payments p WHERE p.id=target_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;
  SELECT i.amount_due,m.person_id,k.id INTO installment_amount_due,installment_person_id,target_kuri_id
  FROM public.installments i JOIN public.memberships m ON m.id=i.membership_id JOIN public.kuris k ON k.id=m.kuri_id
  WHERE i.id=target_installment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Installment not found.'; END IF;
  IF payment_kuri_id<>target_kuri_id THEN RAISE EXCEPTION 'Payment and installment belong to different Kuris.'; END IF;
  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor_user_id,target_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;
  SELECT f.* INTO idem_row FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id AND f.operation_type='PAYMENT_ALLOCATION' AND f.idempotency_key=normalized_key FOR UPDATE;
  IF idem_row.request_hash<>request_hash THEN RAISE EXCEPTION 'Idempotency key was already used for a different allocation request.'; END IF;
  IF idem_row.status='COMPLETED' THEN RETURN idem_row.result_bigint; END IF;
  IF payment_person_id<>installment_person_id THEN RAISE EXCEPTION 'Payment person does not match installment person.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN RAISE EXCEPTION 'You do not have permission to allocate this payment.'; END IF;
  IF payment_status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be allocated.'; END IF;
  payment_total:=public.get_effective_payment_amount(target_payment_id);
  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) INTO already_allocated
  FROM public.payment_allocations pa WHERE pa.payment_id=target_payment_id;
  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) INTO installment_allocated
  FROM public.payment_allocations pa WHERE pa.installment_id=target_installment_id;
  IF already_allocated+allocation_amount>payment_total THEN RAISE EXCEPTION 'Allocation exceeds payment amount.'; END IF;
  IF installment_allocated+allocation_amount>installment_amount_due THEN RAISE EXCEPTION 'Allocation exceeds installment balance.'; END IF;
  INSERT INTO public.payment_allocations(payment_id,installment_id,amount,allocated_by)
  VALUES(target_payment_id,target_installment_id,allocation_amount,(SELECT id FROM public.users WHERE id=v_actor_user_id))
  ON CONFLICT(payment_id,installment_id) DO UPDATE SET
    amount=public.payment_allocations.amount+excluded.amount,allocated_at=now(),allocated_by=excluded.allocated_by;
  SELECT public.reconcile_installment_from_allocations(target_installment_id) INTO next_paid;
  UPDATE public.financial_idempotency_keys SET status='COMPLETED',result_bigint=next_paid,completed_at=now() WHERE id=idem_row.id;
  RETURN next_paid;
END;
$$;
REVOKE ALL ON FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.allocate_payment_for_admin(uuid,uuid,bigint,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.audit_financial_ledger_for_admin(target_kuri_id uuid)
RETURNS TABLE(approved_payment_total bigint,allocation_total bigint,installment_paid_total bigint,unallocated_approved_payment bigint,installment_allocation_gap bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to audit this Kuri financial ledger.';
  END IF;
  RETURN QUERY
  WITH approved AS (
    SELECT coalesce(sum(public.get_effective_payment_amount(p.id)),0) total FROM public.payments p
    WHERE p.status='APPROVED' AND p.kuri_id=target_kuri_id
  ), allocated AS (
    SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) total
    FROM public.payment_allocations pa JOIN public.payments p ON p.id=pa.payment_id
    WHERE p.kuri_id=target_kuri_id
  ), installment_paid AS (
    SELECT coalesce(sum(i.amount_paid),0) total FROM public.installments i
    JOIN public.memberships m ON m.id=i.membership_id WHERE m.kuri_id=target_kuri_id
  )
  SELECT approved.total,allocated.total,installment_paid.total,
         greatest(approved.total-allocated.total,0),greatest(installment_paid.total-allocated.total,0)
  FROM approved,allocated,installment_paid;
END;
$$;

CREATE OR REPLACE FUNCTION public.refresh_membership_exit_financials_for_admin(target_exit_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public
AS $$
DECLARE target_kuri_id uuid; target_membership_id uuid; contributed_amount bigint:=0;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  SELECT k.id,me.membership_id INTO target_kuri_id,target_membership_id
  FROM public.membership_exits me JOIN public.memberships m ON m.id=me.membership_id
  JOIN public.kuris k ON k.id=m.kuri_id WHERE me.id=target_exit_id;
  IF target_kuri_id IS NULL THEN RAISE EXCEPTION 'Exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to refresh this exit.';
  END IF;
  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) INTO contributed_amount
  FROM public.payment_allocations pa JOIN public.payments pay ON pay.id=pa.payment_id
  JOIN public.installments i ON i.id=pa.installment_id
  WHERE i.membership_id=target_membership_id AND pay.status='APPROVED' AND pay.kuri_id=target_kuri_id;
  UPDATE public.membership_exits me SET amount_contributed=contributed_amount,
    refund_amount=case when coalesce(me.refund_amount,0)=0 then contributed_amount
                       else least(me.refund_amount,contributed_amount) end
  WHERE me.id=target_exit_id;
END;
$$;
