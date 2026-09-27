-- PAYMENT-003: idempotency/replay protection for payment correction/reversal requests
alter table public.payment_adjustment_requests
  add column if not exists idempotency_key text,
  add column if not exists request_hash text;

create unique index if not exists payment_adjustment_requests_idempotency_uq
  on public.payment_adjustment_requests(requested_by, adjustment_type, idempotency_key)
  where idempotency_key is not null;

create or replace function public.create_payment_correction_request_for_admin(
  target_payment_id uuid,
  corrected_amount bigint,
  corrected_payment_date timestamptz,
  corrected_method public.payment_method,
  corrected_reference_number text,
  corrected_proof_file_id uuid,
  corrected_notes text,
  reason text,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  actor_user_id uuid := auth.uid();
  payment_kuri_id uuid;
  payment_org_id uuid;
  payment_status public.payment_status;
  current_amount bigint;
  current_payment_date timestamptz;
  current_method public.payment_method;
  current_reference text;
  current_proof uuid;
  current_notes text;
  latest_correction_id uuid;
  request_id uuid;
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  existing_request public.payment_adjustment_requests%rowtype;
begin
  if actor_user_id is null then raise exception 'You must be signed in.'; end if;
  if normalized_key is null or char_length(normalized_key)>200 then
    raise exception 'A valid idempotency key is required.';
  end if;
  if corrected_amount<=0 then raise exception 'Corrected payment amount must be greater than zero.'; end if;
  if nullif(btrim(reason),'') is null then raise exception 'A reason is required.'; end if;

  request_hash := encode(extensions.digest(jsonb_build_array(
    target_payment_id::text,corrected_amount::text,corrected_payment_date::text,
    corrected_method::text,coalesce(btrim(corrected_reference_number),''),
    coalesce(corrected_proof_file_id::text,''),coalesce(btrim(corrected_notes),''),
    btrim(reason)
  )::text,'sha256'),'hex');

  select r.* into existing_request
  from public.payment_adjustment_requests r
  where r.requested_by=actor_user_id
    and r.adjustment_type='CORRECTION'
    and r.idempotency_key=normalized_key
  for update;

  if found then
    if existing_request.request_hash<>request_hash then
      raise exception 'Idempotency key was already used for a different correction request.';
    end if;
    return existing_request.id;
  end if;

  select p.kuri_id,p.organization_id,p.status,p.amount,p.payment_date,p.method,
         p.reference_number,p.proof_file_id,p.notes
    into payment_kuri_id,payment_org_id,payment_status,current_amount,
         current_payment_date,current_method,current_reference,current_proof,current_notes
  from public.payments p where p.id=target_payment_id for update;
  if not found then raise exception 'Payment not found.'; end if;
  if payment_status<>'APPROVED' then raise exception 'Only approved payments can be corrected.'; end if;
  if not public.has_kuri_admin_role(payment_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to correct this payment.';
  end if;

  if corrected_proof_file_id is not null and not exists (
    select 1 from public.files f
    where f.id=corrected_proof_file_id and f.organization_id=payment_org_id
  ) then raise exception 'Proof file does not belong to this organization.'; end if;

  select pc.id,pc.corrected_amount,pc.corrected_payment_date,pc.corrected_method,
         pc.corrected_reference_number,pc.corrected_proof_file_id,pc.corrected_notes
    into latest_correction_id,current_amount,current_payment_date,current_method,
         current_reference,current_proof,current_notes
  from public.payment_corrections pc
  where pc.payment_id=target_payment_id
  order by pc.applied_at desc,pc.id desc limit 1;

  if corrected_amount=current_amount and corrected_payment_date=current_payment_date
     and corrected_method=current_method
     and corrected_reference_number is not distinct from current_reference
     and corrected_proof_file_id is not distinct from current_proof
     and corrected_notes is not distinct from current_notes then
    raise exception 'Correction does not change the recorded payment.';
  end if;

  if corrected_amount < coalesce((
    select sum(public.get_effective_payment_allocation_amount(pa.id))
    from public.payment_allocations pa where pa.payment_id=target_payment_id
  ),0) then
    raise exception 'Corrected amount cannot be less than the currently allocated amount.';
  end if;

  insert into public.payment_adjustment_requests(
    organization_id,kuri_id,payment_id,adjustment_type,status,base_correction_id,
    corrected_amount,corrected_payment_date,corrected_method,corrected_reference_number,
    corrected_proof_file_id,corrected_notes,reason,requested_by,idempotency_key,request_hash
  ) values(
    payment_org_id,payment_kuri_id,target_payment_id,'CORRECTION','REQUESTED',latest_correction_id,
    corrected_amount,corrected_payment_date,corrected_method,nullif(btrim(corrected_reference_number),''),
    corrected_proof_file_id,nullif(btrim(corrected_notes),''),btrim(reason),actor_user_id,
    normalized_key,request_hash
  ) returning id into request_id;

  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason)
  values(payment_org_id,actor_user_id,'payment_correction_requested','payment_adjustment_request',
         request_id,null,(select to_jsonb(r) from public.payment_adjustment_requests r where r.id=request_id),
         btrim(reason));
  return request_id;
end;
$function$;

create or replace function public.create_payment_reversal_request_for_admin(
  target_payment_id uuid,
  reversal_amount bigint,
  target_allocation_id uuid,
  reason text,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  actor_user_id uuid := auth.uid();
  payment_kuri_id uuid;
  payment_org_id uuid;
  payment_status public.payment_status;
  effective_payment_amount bigint;
  effective_allocated_total bigint;
  target_allocation_amount bigint;
  target_allocation_payment_id uuid;
  request_id uuid;
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  existing_request public.payment_adjustment_requests%rowtype;
begin
  if actor_user_id is null then raise exception 'You must be signed in.'; end if;
  if normalized_key is null or char_length(normalized_key)>200 then
    raise exception 'A valid idempotency key is required.';
  end if;
  if reversal_amount<=0 then raise exception 'Reversal amount must be greater than zero.'; end if;
  if nullif(btrim(reason),'') is null then raise exception 'A reason is required.'; end if;

  request_hash := encode(extensions.digest(jsonb_build_array(
    target_payment_id::text,reversal_amount::text,
    coalesce(target_allocation_id::text,''),btrim(reason)
  )::text,'sha256'),'hex');

  select r.* into existing_request
  from public.payment_adjustment_requests r
  where r.requested_by=actor_user_id
    and r.adjustment_type='REVERSAL'
    and r.idempotency_key=normalized_key
  for update;

  if found then
    if existing_request.request_hash<>request_hash then
      raise exception 'Idempotency key was already used for a different reversal request.';
    end if;
    return existing_request.id;
  end if;

  select p.kuri_id,p.organization_id,p.status into payment_kuri_id,payment_org_id,payment_status
  from public.payments p where p.id=target_payment_id for update;
  if not found then raise exception 'Payment not found.'; end if;
  if payment_status<>'APPROVED' then raise exception 'Only approved payments can be reversed.'; end if;
  if not public.has_kuri_admin_role(payment_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to reverse this payment.';
  end if;

  effective_payment_amount:=public.get_effective_payment_amount(target_payment_id);
  if effective_payment_amount<=0 then raise exception 'Payment is already fully reversed.'; end if;

  select coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0)
    into effective_allocated_total
  from public.payment_allocations pa where pa.payment_id=target_payment_id;

  if target_allocation_id is not null then
    select pa.payment_id,public.get_effective_payment_allocation_amount(pa.id)
      into target_allocation_payment_id,target_allocation_amount
    from public.payment_allocations pa where pa.id=target_allocation_id for update;
    if not found then raise exception 'Allocation not found.'; end if;
    if target_allocation_payment_id<>target_payment_id then raise exception 'Target allocation does not belong to this payment.'; end if;
    if target_allocation_amount<=0 then raise exception 'Target allocation is already fully reversed.'; end if;
    if reversal_amount>target_allocation_amount then raise exception 'Reversal exceeds the allocation amount available to reverse.'; end if;
  else
    if reversal_amount>effective_payment_amount then raise exception 'Reversal exceeds the unreversed payment amount.'; end if;
    if effective_allocated_total>0 and reversal_amount<>effective_payment_amount then
      raise exception 'A partial payment-level reversal with existing allocations requires a target allocation.';
    end if;
  end if;

  insert into public.payment_adjustment_requests(
    organization_id,kuri_id,payment_id,adjustment_type,status,requested_amount,
    target_allocation_id,reason,requested_by,idempotency_key,request_hash
  ) values(
    payment_org_id,payment_kuri_id,target_payment_id,'REVERSAL','REQUESTED',reversal_amount,
    target_allocation_id,btrim(reason),actor_user_id,normalized_key,request_hash
  ) returning id into request_id;

  insert into public.audit_logs(organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason)
  values(payment_org_id,actor_user_id,'payment_reversal_requested','payment_adjustment_request',
         request_id,null,(select to_jsonb(r) from public.payment_adjustment_requests r where r.id=request_id),
         btrim(reason));
  return request_id;
end;
$function$;

revoke execute on function public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text) from public,anon;
grant execute on function public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text) to authenticated;
revoke execute on function public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text) from public,anon;
grant execute on function public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text) to authenticated;
revoke execute on function public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text,text) from public,anon;
grant execute on function public.create_payment_correction_request_for_admin(uuid,bigint,timestamptz,public.payment_method,text,uuid,text,text,text) to authenticated;
revoke execute on function public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text,text) from public,anon;
grant execute on function public.create_payment_reversal_request_for_admin(uuid,bigint,uuid,text,text) to authenticated;
