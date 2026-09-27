-- Production reconciliation: operational APIs follow the current succession holder while preserving historical person identity.
CREATE OR REPLACE FUNCTION public.create_payment_for_admin(target_kuri_id uuid, target_person_id uuid, payment_amount bigint, payment_date timestamp with time zone, payment_method payment_method, payment_reference text, payment_notes text, p_idempotency_key text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  payment_id uuid;
  target_org_id uuid;
  v_actor_user_id uuid := (select auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF payment_amount<=0 THEN RAISE EXCEPTION 'Payment amount must be greater than zero.'; END IF;

  request_hash := encode(extensions.digest(
    jsonb_build_array(
      target_kuri_id::text,target_person_id::text,payment_amount::text,
      payment_date::text,payment_method::text,
      coalesce(btrim(payment_reference),''),coalesce(btrim(payment_notes),'')
    )::text,'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(
    actor_user_id,kuri_id,operation_type,idempotency_key,request_hash
  )
  VALUES(v_actor_user_id,target_kuri_id,'PAYMENT_CREATE',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id
    AND f.operation_type='PAYMENT_CREATE'
    AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different payment request.';
  END IF;
  IF idem_row.status='COMPLETED' THEN
    RETURN idem_row.result_payment_id;
  END IF;

  SELECT k.organization_id INTO target_org_id
  FROM public.kuris k WHERE k.id=target_kuri_id;
  IF target_org_id IS NULL THEN RAISE EXCEPTION 'Kuri not found.'; END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to record payments for this Kuri.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.memberships m
    WHERE m.kuri_id=target_kuri_id
      AND coalesce(m.current_holder_person_id,m.person_id)=target_person_id
  ) THEN
    RAISE EXCEPTION 'Person is not a member of this Kuri.';
  END IF;

  INSERT INTO public.payments(
    kuri_id,organization_id,person_id,amount,payment_date,method,
    reference_number,status,notes
  )
  VALUES(
    target_kuri_id,target_org_id,target_person_id,payment_amount,payment_date,
    payment_method,nullif(btrim(payment_reference),''),
    'APPROVED',nullif(btrim(payment_notes),'')
  )
  RETURNING id INTO payment_id;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_payment_id=payment_id,completed_at=now()
  WHERE id=idem_row.id;

  RETURN payment_id;
END $function$;

CREATE OR REPLACE FUNCTION public.allocate_payment_for_admin(target_payment_id uuid, target_installment_id uuid, allocation_amount bigint, p_idempotency_key text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_actor_user_id uuid := (SELECT auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
  payment_person_id uuid;
  payment_total bigint;
  payment_status public.payment_status;
  payment_kuri_id uuid;
  installment_person_id uuid;
  membership_current_holder_id uuid;
  installment_amount_due bigint;
  target_kuri_id uuid;
  target_membership_id uuid;
  target_cycle_number integer;
  already_allocated bigint;
  installment_allocated bigint;
  next_paid bigint;
  earlier_outstanding bigint;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF allocation_amount<=0 THEN RAISE EXCEPTION 'Allocation amount must be greater than zero.'; END IF;

  request_hash:=encode(extensions.digest(
    jsonb_build_array(target_payment_id::text,target_installment_id::text,allocation_amount::text)::text,
    'sha256'),'hex');

  SELECT p.person_id,p.status,p.kuri_id
    INTO payment_person_id,payment_status,payment_kuri_id
  FROM public.payments p
  WHERE p.id=target_payment_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;

  SELECT i.amount_due,m.person_id,m.current_holder_person_id,m.id,c.kuri_id,c.cycle_number
    INTO installment_amount_due,installment_person_id,membership_current_holder_id,
         target_membership_id,target_kuri_id,target_cycle_number
  FROM public.installments i
  JOIN public.memberships m ON m.id=i.membership_id
  JOIN public.cycles c ON c.id=i.cycle_id
  WHERE i.id=target_installment_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Installment not found.'; END IF;

  IF payment_kuri_id<>target_kuri_id THEN
    RAISE EXCEPTION 'Payment and installment belong to different Kuris.';
  END IF;

  IF payment_person_id<>installment_person_id
     AND (membership_current_holder_id IS NULL OR payment_person_id<>membership_current_holder_id) THEN
    RAISE EXCEPTION 'Payment person does not match the original member or current holder.';
  END IF;

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor_user_id,target_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id
    AND f.operation_type='PAYMENT_ALLOCATION'
    AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different allocation request.';
  END IF;
  IF idem_row.status='COMPLETED' THEN RETURN idem_row.result_bigint; END IF;

  IF NOT public.has_kuri_admin_role(
    target_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to allocate this payment.';
  END IF;
  IF payment_status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be allocated.'; END IF;

  PERFORM 1
  FROM public.installments lock_i
  JOIN public.cycles lock_c ON lock_c.id=lock_i.cycle_id
  WHERE lock_i.membership_id=target_membership_id
  ORDER BY lock_c.cycle_number,lock_i.id
  FOR UPDATE;

  SELECT coalesce(sum(greatest(oi.amount_due-oi.effective_paid,0)),0)
    INTO earlier_outstanding
  FROM (
    SELECT oi.id,oi.amount_due,
      least(
        coalesce((
          SELECT sum(public.get_effective_payment_allocation_amount(pa.id))
          FROM public.payment_allocations pa
          WHERE pa.installment_id=oi.id
        ),0),
        oi.amount_due
      ) AS effective_paid,
      oc.cycle_number
    FROM public.installments oi
    JOIN public.cycles oc ON oc.id=oi.cycle_id
    WHERE oi.membership_id=target_membership_id
  ) oi
  WHERE oi.cycle_number<target_cycle_number;

  IF earlier_outstanding>0 THEN
    RAISE EXCEPTION 'Cannot skip outstanding earlier installments. Allocate the oldest outstanding installment first.';
  END IF;

  payment_total:=public.get_effective_payment_amount(target_payment_id);

  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    INTO already_allocated
  FROM public.payment_allocations pa
  WHERE pa.payment_id=target_payment_id;

  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    INTO installment_allocated
  FROM public.payment_allocations pa
  WHERE pa.installment_id=target_installment_id;

  IF already_allocated+allocation_amount>payment_total THEN
    RAISE EXCEPTION 'Allocation exceeds payment amount.';
  END IF;
  IF installment_allocated>=installment_amount_due THEN
    RAISE EXCEPTION 'Target installment is already fully paid.';
  END IF;
  IF installment_allocated+allocation_amount>installment_amount_due THEN
    RAISE EXCEPTION 'Allocation exceeds installment balance. Use the advance-payment allocation API to span multiple installments.';
  END IF;

  INSERT INTO public.payment_allocations(payment_id,installment_id,amount,allocated_by)
  VALUES(
    target_payment_id,target_installment_id,allocation_amount,
    (SELECT id FROM public.users WHERE id=v_actor_user_id)
  )
  ON CONFLICT(payment_id,installment_id)
  DO UPDATE SET
    amount=public.payment_allocations.amount+excluded.amount,
    allocated_at=now(),
    allocated_by=excluded.allocated_by;

  SELECT public.reconcile_installment_from_allocations(target_installment_id)
    INTO next_paid;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_bigint=next_paid,completed_at=now()
  WHERE id=idem_row.id;

  RETURN next_paid;
END
$function$;

CREATE OR REPLACE FUNCTION public.allocate_payment_to_oldest_installments_for_admin(target_payment_id uuid, target_membership_id uuid, requested_allocation_amount bigint, p_idempotency_key text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_actor_user_id uuid := (SELECT auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
  payment_person_id uuid;
  payment_kuri_id uuid;
  payment_status public.payment_status;
  membership_person_id uuid;
  membership_current_holder_id uuid;
  membership_kuri_id uuid;
  effective_payment_amount bigint;
  already_allocated bigint;
  available_payment bigint;
  total_outstanding bigint;
  remaining bigint;
  chunk bigint;
  installment_allocated bigint;
  effective_installment_paid bigint;
  actor_db_user_id uuid;
  inst record;
  total_allocated bigint:=0;
BEGIN
  IF v_actor_user_id IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN RAISE EXCEPTION 'A valid idempotency key is required.'; END IF;
  IF requested_allocation_amount<=0 THEN RAISE EXCEPTION 'Allocation amount must be greater than zero.'; END IF;

  request_hash:=encode(extensions.digest(
    jsonb_build_array(target_payment_id::text,target_membership_id::text,requested_allocation_amount::text)::text,
    'sha256'),'hex');

  SELECT p.person_id,p.kuri_id,p.status
    INTO payment_person_id,payment_kuri_id,payment_status
  FROM public.payments p
  WHERE p.id=target_payment_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Payment not found.'; END IF;

  SELECT m.person_id,m.current_holder_person_id,m.kuri_id
    INTO membership_person_id,membership_current_holder_id,membership_kuri_id
  FROM public.memberships m
  WHERE m.id=target_membership_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Membership not found.'; END IF;

  IF payment_kuri_id<>membership_kuri_id THEN
    RAISE EXCEPTION 'Payment and membership belong to different Kuris.';
  END IF;
  IF payment_person_id<>membership_person_id
     AND (membership_current_holder_id IS NULL OR payment_person_id<>membership_current_holder_id) THEN
    RAISE EXCEPTION 'Payment person does not match the original member or current holder.';
  END IF;

  IF NOT public.has_kuri_admin_role(
    membership_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) THEN
    RAISE EXCEPTION 'You do not have permission to allocate this payment.';
  END IF;
  IF payment_status<>'APPROVED' THEN RAISE EXCEPTION 'Only approved payments can be allocated.'; END IF;

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor_user_id,membership_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id
    AND f.operation_type='PAYMENT_ALLOCATION'
    AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different allocation request.';
  END IF;
  IF idem_row.status='COMPLETED' THEN RETURN idem_row.result_bigint; END IF;

  actor_db_user_id := (SELECT id FROM public.users WHERE id=v_actor_user_id);

  PERFORM 1
  FROM public.installments lock_i
  JOIN public.cycles lock_c ON lock_c.id=lock_i.cycle_id
  WHERE lock_i.membership_id=target_membership_id
  ORDER BY lock_c.cycle_number,lock_i.id
  FOR UPDATE;

  effective_payment_amount:=public.get_effective_payment_amount(target_payment_id);

  SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    INTO already_allocated
  FROM public.payment_allocations pa
  WHERE pa.payment_id=target_payment_id;

  available_payment:=greatest(effective_payment_amount-already_allocated,0);

  IF requested_allocation_amount>available_payment THEN
    RAISE EXCEPTION 'Allocation exceeds the payment amount available for allocation.';
  END IF;

  SELECT coalesce(sum(greatest(x.amount_due-x.effective_paid,0)),0)
    INTO total_outstanding
  FROM (
    SELECT oi.amount_due,
      least(
        coalesce((
          SELECT sum(public.get_effective_payment_allocation_amount(pa2.id))
          FROM public.payment_allocations pa2
          WHERE pa2.installment_id=oi.id
        ),0),
        oi.amount_due
      ) AS effective_paid
    FROM public.installments oi
    WHERE oi.membership_id=target_membership_id
  ) x;

  IF requested_allocation_amount>total_outstanding THEN
    RAISE EXCEPTION 'Allocation exceeds the total outstanding installments for this membership.';
  END IF;

  remaining:=requested_allocation_amount;

  FOR inst IN
    SELECT oi.id,oi.amount_due,oc.cycle_number
    FROM public.installments oi
    JOIN public.cycles oc ON oc.id=oi.cycle_id
    WHERE oi.membership_id=target_membership_id
    ORDER BY oc.cycle_number,oi.id
  LOOP
    EXIT WHEN remaining=0;

    SELECT coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
      INTO installment_allocated
    FROM public.payment_allocations pa
    WHERE pa.installment_id=inst.id;

    effective_installment_paid:=least(installment_allocated,inst.amount_due);
    chunk:=least(remaining,greatest(inst.amount_due-effective_installment_paid,0));

    IF chunk>0 THEN
      INSERT INTO public.payment_allocations(payment_id,installment_id,amount,allocated_by)
      VALUES(target_payment_id,inst.id,chunk,actor_db_user_id)
      ON CONFLICT(payment_id,installment_id)
      DO UPDATE SET
        amount=public.payment_allocations.amount+excluded.amount,
        allocated_at=now(),
        allocated_by=excluded.allocated_by;

      PERFORM public.reconcile_installment_from_allocations(inst.id);
      remaining:=remaining-chunk;
      total_allocated:=total_allocated+chunk;
    END IF;
  END LOOP;

  IF remaining<>0 THEN RAISE EXCEPTION 'Unable to allocate the complete requested amount.'; END IF;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_bigint=total_allocated,completed_at=now()
  WHERE id=idem_row.id;

  RETURN total_allocated;
END
$function$;

CREATE OR REPLACE FUNCTION public.list_installments_for_person_payment_admin(target_kuri_id uuid, target_person_id uuid)
 RETURNS TABLE(id uuid, kuri_id uuid, kuri_name text, membership_id uuid, membership_number text, cycle_id uuid, cycle_number integer, amount_due bigint, amount_paid bigint, balance bigint, status installment_status, due_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select i.id,k.id,k.name,m.id,m.membership_number,c.id,c.cycle_number,
         i.amount_due,i.amount_paid,greatest(i.amount_due-i.amount_paid,0),
         i.status,i.due_date
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where coalesce(m.current_holder_person_id,m.person_id)=target_person_id
    and k.id=target_kuri_id
    and greatest(i.amount_due-i.amount_paid,0)>0
    and public.has_kuri_admin_role(
      target_kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by c.cycle_number,m.membership_number;
$function$;

CREATE OR REPLACE FUNCTION public.list_installments_for_cycle_admin(target_cycle_id uuid)
 RETURNS TABLE(id uuid, membership_id uuid, membership_number text, registered_name text, display_name text, amount_due bigint, amount_paid bigint, status installment_status, due_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select i.id,i.membership_id,m.membership_number,p.registered_name,
         p.display_name,i.amount_due,i.amount_paid,i.status,i.due_date
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.people p on p.id=coalesce(m.current_holder_person_id,m.person_id)
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where i.cycle_id=target_cycle_id
    and public.has_kuri_admin_role(
      k.id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by m.membership_number;
$function$;

CREATE OR REPLACE FUNCTION public.list_installments_for_payment_admin(target_kuri_id uuid)
 RETURNS TABLE(id uuid, membership_id uuid, membership_number text, registered_name text, display_name text, cycle_id uuid, cycle_number integer, amount_due bigint, amount_paid bigint, balance bigint, status installment_status, due_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select i.id,i.membership_id,m.membership_number,p.registered_name,
         p.display_name,i.cycle_id,c.cycle_number,i.amount_due,i.amount_paid,
         greatest(i.amount_due-i.amount_paid,0),i.status,i.due_date
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.people p on p.id=coalesce(m.current_holder_person_id,m.person_id)
  join public.cycles c on c.id=i.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where k.id=target_kuri_id
    and public.has_kuri_admin_role(
      target_kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by c.cycle_number,m.membership_number;
$function$;

CREATE OR REPLACE FUNCTION public.list_memberships_for_admin(target_kuri_id uuid)
 RETURNS TABLE(id uuid, kuri_id uuid, person_id uuid, membership_number text, status membership_status, joined_at timestamp with time zone, registered_name text, display_name text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT
    m.id,m.kuri_id,coalesce(m.current_holder_person_id,m.person_id),m.membership_number,m.status,m.joined_at,
    p.registered_name,p.display_name
  FROM public.memberships m
  JOIN public.people p ON p.id=coalesce(m.current_holder_person_id,m.person_id)
  WHERE m.kuri_id=target_kuri_id
    AND public.has_kuri_admin_role(
      m.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY m.membership_number;
$function$;

CREATE OR REPLACE FUNCTION public.get_draw_selections_for_admin(target_cycle_id uuid)
 RETURNS TABLE(selection_id uuid, selection_order integer, membership_id uuid, membership_number text, registered_name text, display_name text, randomization_id text, selected_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT s.id,s.selection_order,m.id,m.membership_number,p.registered_name,p.display_name,
         s.randomization_id,s.selected_at
  FROM public.draw_selections s
  JOIN public.draw_sessions d ON d.id=s.draw_session_id
  JOIN public.cycles c ON c.id=d.cycle_id
  JOIN public.memberships m ON m.id=s.membership_id
  JOIN public.people p ON p.id=coalesce(m.current_holder_person_id,m.person_id)
  WHERE c.id=target_cycle_id
    AND public.has_kuri_admin_role(
      d.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY s.selection_order;
$function$;

CREATE OR REPLACE FUNCTION public.run_random_draw_for_admin(target_cycle_id uuid, selection_count integer DEFAULT 1, p_idempotency_key text DEFAULT NULL::text)
 RETURNS TABLE(selection_order integer, membership_id uuid, membership_number text, registered_name text, display_name text, randomization_id text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_user_id uuid := (SELECT auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
  session_id uuid;
  candidate_count integer;
  draw_status_value public.draw_status;
  cycle_status_value public.cycle_status;
  target_kuri_id uuid;
BEGIN
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  IF selection_count IS NULL OR selection_count<1 THEN
    RAISE EXCEPTION 'Selection count must be at least 1.';
  END IF;

  SELECT c.kuri_id
    INTO target_kuri_id
  FROM public.cycles c
  WHERE c.id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );

  IF target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'You do not have permission to manage this draw.';
  END IF;

  IF normalized_key IS NULL OR char_length(normalized_key)>200 THEN
    RAISE EXCEPTION 'A valid idempotency key is required.';
  END IF;

  request_hash:=encode(
    extensions.digest(
      jsonb_build_array(
        target_cycle_id::text,
        selection_count::text
      )::text,
      'sha256'
    ),
    'hex'
  );

  INSERT INTO public.financial_idempotency_keys(
    actor_user_id,kuri_id,operation_type,idempotency_key,request_hash
  )
  VALUES(
    v_actor_user_id,target_kuri_id,'DRAW_RUN',normalized_key,request_hash
  )
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.*
    INTO idem_row
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor_user_id
    AND f.operation_type='DRAW_RUN'
    AND f.idempotency_key=normalized_key
  FOR UPDATE;

  IF idem_row.request_hash<>request_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different draw request.';
  END IF;

  -- A completed retry returns the frozen selection set rather than running
  -- randomness again.
  IF idem_row.status='COMPLETED' THEN
    RETURN QUERY
    SELECT
      s.selection_order,
      s.membership_id,
      m.membership_number,
      p.registered_name,
      p.display_name,
      s.randomization_id
    FROM public.draw_selections s
    JOIN public.draw_sessions d ON d.id=s.draw_session_id
    JOIN public.memberships m ON m.id=s.membership_id
    JOIN public.people p ON p.id=coalesce(m.current_holder_person_id,m.person_id)
    WHERE d.cycle_id=target_cycle_id
    ORDER BY s.selection_order;
    RETURN;
  END IF;

  SELECT d.id,d.status,c.status,c.kuri_id
    INTO session_id,draw_status_value,cycle_status_value,target_kuri_id
  FROM public.draw_sessions d
  JOIN public.cycles c ON c.id=d.cycle_id
  WHERE d.cycle_id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF d,c;

  IF session_id IS NULL THEN
    RAISE EXCEPTION 'Prepare the draw first.';
  END IF;

  IF cycle_status_value<>'DRAW_PENDING' THEN
    RAISE EXCEPTION 'Cycle must be DRAW_PENDING before running the draw.';
  END IF;

  IF draw_status_value<>'POOL_READY' THEN
    RAISE EXCEPTION 'Draw must be POOL_READY before running the random draw.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.draw_pool_entries e
    WHERE e.draw_session_id=session_id
      AND e.admin_included
      AND NOT e.system_eligible
      AND NOT e.override
  ) THEN
    RAISE EXCEPTION 'Draw pool contains an ineligible membership without an override.';
  END IF;

  SELECT count(*) INTO candidate_count
  FROM public.draw_pool_entries e
  WHERE e.draw_session_id=session_id
    AND e.admin_included;

  IF candidate_count=0 THEN
    RAISE EXCEPTION 'No memberships are included in the draw pool.';
  END IF;

  IF selection_count>candidate_count THEN
    RAISE EXCEPTION 'Selection count exceeds the draw pool.';
  END IF;

  PERFORM public.transition_draw_status_for_admin(session_id,'DRAWING');

  DELETE FROM public.draw_selections
  WHERE draw_session_id=session_id;

  INSERT INTO public.draw_selections(
    draw_session_id,membership_id,selection_order,randomization_id
  )
  SELECT
    session_id,picked.membership_id,picked.rn,gen_random_uuid()::text
  FROM (
    SELECT
      e.membership_id,
      row_number() OVER (ORDER BY random())::integer rn
    FROM public.draw_pool_entries e
    WHERE e.draw_session_id=session_id
      AND e.admin_included
    ORDER BY random()
    LIMIT selection_count
  ) picked;

  PERFORM public.transition_draw_status_for_admin(session_id,'RESULTS_READY');

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',
      result_bigint=selection_count,
      completed_at=now()
  WHERE id=idem_row.id;

  RETURN QUERY
  SELECT
    s.selection_order,
    s.membership_id,
    m.membership_number,
    p.registered_name,
    p.display_name,
    s.randomization_id
  FROM public.draw_selections s
  JOIN public.memberships m ON m.id=s.membership_id
  JOIN public.people p ON p.id=coalesce(m.current_holder_person_id,m.person_id)
  WHERE s.draw_session_id=session_id
  ORDER BY s.selection_order;
END;
$function$;

CREATE OR REPLACE FUNCTION public.finalize_draw_for_admin(target_cycle_id uuid, final_membership_ids uuid[], p_idempotency_key text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_actor uuid:=(SELECT auth.uid());
  v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text;
  v_idem public.financial_idempotency_keys%rowtype;
  v_session_id uuid;
  v_kuri_id uuid;
  v_cycle_status public.cycle_status;
  v_draw_status public.draw_status;
  v_winner_count integer;
  v_selected_count integer;
  v_selected_person_count integer;
  v_unwon_member_count integer;
  v_remaining_cycles integer;
  v_max_winners integer;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;
  IF final_membership_ids IS NULL OR cardinality(final_membership_ids)<1 THEN
    RAISE EXCEPTION 'Select at least one winner.';
  END IF;
  IF cardinality(final_membership_ids) <> cardinality(array(select distinct unnest(final_membership_ids))) THEN
    RAISE EXCEPTION 'Duplicate winner memberships are not allowed.';
  END IF;
  IF v_key IS NULL OR char_length(v_key)>200 THEN
    RAISE EXCEPTION 'A valid idempotency key is required.';
  END IF;

  SELECT c.kuri_id INTO v_kuri_id
  FROM public.cycles c
  WHERE c.id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );
  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'You do not have permission to manage this draw.'; END IF;

  v_hash:=encode(extensions.digest(
    jsonb_build_object('cycle_id',target_cycle_id::text,'membership_ids',to_jsonb(final_membership_ids))::text,
    'sha256'),'hex');

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor,v_kuri_id,'DRAW_FINALIZE',v_key,v_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT f.* INTO v_idem
  FROM public.financial_idempotency_keys f
  WHERE f.actor_user_id=v_actor
    AND f.operation_type='DRAW_FINALIZE'
    AND f.idempotency_key=v_key
  FOR UPDATE;

  IF v_idem.request_hash<>v_hash THEN
    RAISE EXCEPTION 'Idempotency key was already used for a different finalization request.';
  END IF;
  IF v_idem.status='COMPLETED' THEN
    SELECT count(*) INTO v_winner_count FROM public.monthly_winners WHERE cycle_id=target_cycle_id;
    RETURN v_winner_count;
  END IF;

  SELECT d.id,c.kuri_id,c.status,d.status
    INTO v_session_id,v_kuri_id,v_cycle_status,v_draw_status
  FROM public.draw_sessions d
  JOIN public.cycles c ON c.id=d.cycle_id
  WHERE d.cycle_id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF d,c;

  IF v_session_id IS NULL THEN RAISE EXCEPTION 'Prepare and run the draw before finalizing winners.'; END IF;
  PERFORM 1 FROM public.kuris k WHERE k.id=v_kuri_id FOR UPDATE;

  IF v_cycle_status<>'DRAW_PENDING' THEN RAISE EXCEPTION 'Cycle must be DRAW_PENDING before finalizing winners.'; END IF;
  IF v_draw_status<>'RESULTS_READY' THEN RAISE EXCEPTION 'Draw must have RESULTS_READY status before finalizing winners.'; END IF;
  IF EXISTS(SELECT 1 FROM public.monthly_winners WHERE cycle_id=target_cycle_id) THEN
    RAISE EXCEPTION 'Winners are already finalized for this cycle.';
  END IF;

  SELECT count(*) INTO v_selected_count
  FROM public.draw_selections s
  WHERE s.draw_session_id=v_session_id
    AND s.membership_id=ANY(final_membership_ids);
  IF v_selected_count<>array_length(final_membership_ids,1) THEN
    RAISE EXCEPTION 'Final winners must come from the current draw selections.';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM public.memberships m
    JOIN public.membership_exits me ON me.membership_id=m.id
    WHERE m.id=ANY(final_membership_ids)
      AND me.reason='DEATH'
      AND me.death_date_verified_at IS NOT NULL
      AND me.death_date<=current_date
      AND me.status IN ('PENDING','APPROVED')
  ) THEN
    RAISE EXCEPTION 'A verified-deceased membership cannot be finalized as a winner.';
  END IF;

  SELECT count(DISTINCT coalesce(m.current_holder_person_id,m.person_id))
    INTO v_selected_person_count
  FROM public.memberships m
  WHERE m.id=ANY(final_membership_ids);
  IF v_selected_person_count<>array_length(final_membership_ids,1) THEN
    RAISE EXCEPTION 'Only one winner per current holder can be finalized in a cycle.';
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.memberships m
    WHERE m.id=ANY(final_membership_ids)
      AND (m.kuri_id<>v_kuri_id OR m.status<>'ACTIVE')
  ) THEN
    RAISE EXCEPTION 'A final winner must be an ACTIVE membership in the draw Kuri.';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM public.memberships m
    JOIN public.monthly_winners mw
      ON mw.person_id=coalesce(m.current_holder_person_id,m.person_id)
    JOIN public.cycles wc ON wc.id=mw.cycle_id
    WHERE m.id=ANY(final_membership_ids)
      AND wc.kuri_id=v_kuri_id
      AND wc.id<>target_cycle_id
  ) THEN
    RAISE EXCEPTION 'A current holder who has already won in this Kuri cannot win again.';
  END IF;

  SELECT count(DISTINCT coalesce(m.current_holder_person_id,m.person_id))
    INTO v_unwon_member_count
  FROM public.memberships m
  WHERE m.kuri_id=v_kuri_id
    AND m.status='ACTIVE'
    AND NOT EXISTS(
      SELECT 1
      FROM public.monthly_winners mw
      JOIN public.cycles wc ON wc.id=mw.cycle_id
      WHERE wc.kuri_id=v_kuri_id
        AND mw.person_id=coalesce(m.current_holder_person_id,m.person_id)
    );

  SELECT greatest(k.number_of_cycles-c.cycle_number+1,0)
    INTO v_remaining_cycles
  FROM public.kuris k JOIN public.cycles c ON c.kuri_id=k.id
  WHERE k.id=v_kuri_id AND c.id=target_cycle_id;

  IF v_remaining_cycles<1 THEN
    RAISE EXCEPTION 'Unable to determine remaining cycles for winner finalization.';
  END IF;
  IF v_unwon_member_count<v_remaining_cycles THEN
    RAISE EXCEPTION 'Insufficient remaining current holders for the remaining cycles; repeating winners is not allowed.';
  END IF;

  v_max_winners:=v_unwon_member_count-(v_remaining_cycles-1);
  IF array_length(final_membership_ids,1)>v_max_winners THEN
    RAISE EXCEPTION 'Selected winner count exceeds the maximum feasible winner count of %.',v_max_winners;
  END IF;

  INSERT INTO public.monthly_winners(
    cycle_id,person_id,selection_source,finalized_by,finalized_at
  )
  SELECT
    target_cycle_id,
    coalesce(m.current_holder_person_id,m.person_id),
    'RANDOM_DRAW',
    (SELECT id FROM public.users WHERE id=auth.uid()),
    now()
  FROM public.memberships m
  WHERE m.id=ANY(final_membership_ids)
  GROUP BY coalesce(m.current_holder_person_id,m.person_id);

  INSERT INTO public.monthly_winner_memberships(monthly_winner_id,membership_id)
  SELECT mw.id,m.id
  FROM public.monthly_winners mw
  JOIN public.memberships m
    ON coalesce(m.current_holder_person_id,m.person_id)=mw.person_id
  WHERE mw.cycle_id=target_cycle_id
    AND m.id=ANY(final_membership_ids);

  PERFORM public.transition_draw_status_for_admin(v_session_id,'FINALIZED');
  PERFORM public.transition_cycle_status_for_admin(target_cycle_id,'COMPLETED');

  SELECT count(*) INTO v_winner_count
  FROM public.monthly_winners
  WHERE cycle_id=target_cycle_id;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_bigint=v_winner_count,completed_at=now()
  WHERE id=v_idem.id;

  RETURN v_winner_count;
END
$function$;