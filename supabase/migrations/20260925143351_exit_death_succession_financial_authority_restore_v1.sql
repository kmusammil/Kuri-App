begin;

create or replace function public.create_membership_exit_for_admin(
  target_membership_id uuid,exit_reason public.settlement_reason,target_exit_date date,
  target_refund_policy public.refund_policy default 'AT_MATURITY',
  target_refund_amount bigint default null,target_notes text default null,p_idempotency_key text default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_kuri_id uuid; v_status public.membership_status; v_exit uuid;
  v_hash text; v_key text:=nullif(btrim(p_idempotency_key),''); v_idem public.financial_idempotency_keys%rowtype;
  v_contributed bigint; v_settlement bigint; v_refund bigint;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  if target_exit_date is null or target_exit_date>current_date then raise exception 'Exit date must not be in the future.'; end if;
  if target_refund_amount is not null and target_refund_amount<0 then raise exception 'Refund amount cannot be negative.'; end if;
  select m.kuri_id,m.status into v_kuri_id,v_status from public.memberships m where m.id=target_membership_id for update;
  if v_kuri_id is null then raise exception 'Membership not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to create an exit for this Kuri.'; end if;
  if v_status not in ('ACTIVE','SUSPENDED') then raise exception 'Only ACTIVE or SUSPENDED memberships can request an exit.'; end if;
  v_hash:=encode(extensions.digest(jsonb_build_array(target_membership_id::text,exit_reason::text,target_exit_date::text,target_refund_policy::text,coalesce(target_refund_amount,-1)::text,coalesce(btrim(target_notes),''))::text,'sha256'),'hex');
  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'EXIT_CREATE',v_key,v_hash) on conflict(actor_user_id,operation_type,idempotency_key) do nothing;
  select * into v_idem from public.financial_idempotency_keys where actor_user_id=v_actor and operation_type='EXIT_CREATE' and idempotency_key=v_key for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different exit request.'; end if;
  if v_idem.status='COMPLETED' then return v_idem.result_reference_id; end if;
  if exists(select 1 from public.membership_exits me where me.membership_id=target_membership_id and me.status not in ('CANCELLED','SETTLED')) then raise exception 'A non-terminal exit request already exists for this membership.'; end if;
  insert into public.membership_exits(membership_id,reason,exit_date,refund_policy,amount_contributed,refund_amount,status,requested_at,notes)
  values(target_membership_id,exit_reason,target_exit_date,target_refund_policy,0,0,'PENDING',now(),nullif(btrim(target_notes),'')) returning id into v_exit;
  select contributed_amount,settlement_amount into v_contributed,v_settlement from public.calculate_membership_exit_financials(v_exit);
  v_refund:=case when target_refund_amount is null then greatest(v_settlement,0) else least(greatest(target_refund_amount,0),greatest(v_settlement,0)) end;
  update public.membership_exits set amount_contributed=greatest(v_contributed,0),refund_amount=v_refund where id=v_exit;
  update public.financial_idempotency_keys set status='COMPLETED',result_reference_id=v_exit,completed_at=now() where id=v_idem.id;
  return v_exit;
end $$;

create or replace function public.approve_membership_exit_for_admin(target_exit_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_kuri_id uuid; v_membership_id uuid; v_status public.settlement_status; v_old_refund bigint; v_contributed bigint; v_settlement bigint;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select m.kuri_id,me.membership_id,me.status,me.refund_amount into v_kuri_id,v_membership_id,v_status,v_old_refund
  from public.membership_exits me join public.memberships m on m.id=me.membership_id where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to approve this exit.'; end if;
  if v_status='APPROVED' then return; end if;
  if v_status<>'PENDING' then raise exception 'Exit is not pending approval.'; end if;
  select contributed_amount,settlement_amount into v_contributed,v_settlement from public.calculate_membership_exit_financials(target_exit_id);
  update public.membership_exits
  set amount_contributed=greatest(coalesce(v_contributed,0),0),
      refund_amount=case when v_old_refund is null then greatest(coalesce(v_settlement,0),0) else least(greatest(v_old_refund,0),greatest(coalesce(v_settlement,0),0)) end,
      approved_by=(select id from public.users where id=auth.uid())
  where id=target_exit_id and status='PENDING';
  if not found then raise exception 'Exit is no longer pending.'; end if;
  perform public.transition_membership_exit_status_for_admin(target_exit_id,'APPROVED');
end $$;

create or replace function public.record_membership_exit_refund_for_admin(
  target_exit_id uuid,refund_amount bigint,refund_payment_method public.payment_method,
  refund_reference text default null,refund_paid_at timestamptz default null,refund_notes text default null,
  p_idempotency_key text default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_kuri_id uuid; v_membership_id uuid; v_status public.settlement_status; v_policy public.refund_policy;
  v_expected bigint; v_paid bigint; v_balance bigint; v_tx uuid; v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text; v_idem public.financial_idempotency_keys%rowtype; v_contributed bigint; v_settlement bigint;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  if refund_amount is null or refund_amount<=0 then raise exception 'Refund amount must be greater than zero.'; end if;
  select m.kuri_id,me.membership_id,me.status,me.refund_policy into v_kuri_id,v_membership_id,v_status,v_policy
  from public.membership_exits me join public.memberships m on m.id=me.membership_id where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to record this refund.'; end if;
  v_hash:=encode(extensions.digest(jsonb_build_array(target_exit_id::text,refund_amount::text,refund_payment_method::text,coalesce(btrim(refund_reference),''),coalesce(refund_paid_at::text,''),coalesce(btrim(refund_notes),''))::text,'sha256'),'hex');
  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'EXIT_REFUND',v_key,v_hash) on conflict(actor_user_id,operation_type,idempotency_key) do nothing;
  select * into v_idem from public.financial_idempotency_keys where actor_user_id=v_actor and operation_type='EXIT_REFUND' and idempotency_key=v_key for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different refund request.'; end if;
  if v_idem.status='COMPLETED' then return v_idem.result_reference_id; end if;
  if v_status<>'APPROVED' or v_policy<>'IMMEDIATE' then raise exception 'Only approved immediate refunds can be paid here.'; end if;
  select contributed_amount,settlement_amount into v_contributed,v_settlement from public.calculate_membership_exit_financials(target_exit_id);
  v_expected:=greatest(v_settlement,0);
  select coalesce(sum(rt.amount),0) into v_paid from public.membership_exit_refund_transactions rt where rt.membership_exit_id=target_exit_id;
  v_balance:=greatest(v_expected-v_paid,0);
  if v_balance<=0 then raise exception 'No refund balance remains for this exit.'; end if;
  if refund_amount>v_balance then raise exception 'Refund exceeds the remaining approved refund balance.'; end if;
  insert into public.membership_exit_refund_transactions(membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes)
  values(target_exit_id,refund_amount,refund_payment_method,nullif(btrim(refund_reference),''),coalesce(refund_paid_at,now()),(select id from public.users where id=v_actor),nullif(btrim(refund_notes),'')) returning id into v_tx;
  select coalesce(sum(rt.amount),0) into v_paid from public.membership_exit_refund_transactions rt where rt.membership_exit_id=target_exit_id;
  update public.membership_exits set amount_contributed=greatest(v_contributed,0),refund_amount=v_expected,
    settled_at=case when v_paid>=v_expected then now() else settled_at end,
    status=case when v_paid>=v_expected then 'SETTLED' else 'APPROVED' end
  where id=target_exit_id and status='APPROVED';
  if v_paid>=v_expected then update public.memberships set status='EXITED',exited_at=coalesce(exited_at,now()) where id=v_membership_id; end if;
  update public.financial_idempotency_keys set status='COMPLETED',result_reference_id=v_tx,completed_at=now() where id=v_idem.id;
  return v_tx;
end $$;

create or replace function public.settle_membership_exit_for_admin(
  target_exit_id uuid,settlement_payment_method public.muppu_settlement_method default 'PAID_IN_ADVANCE',
  settlement_reference text default null,settlement_date timestamptz default null,p_idempotency_key text default null
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_kuri_id uuid; v_membership_id uuid; v_status public.settlement_status; v_policy public.refund_policy; v_reason public.settlement_reason; v_death_verified timestamptz;
  v_key text:=nullif(btrim(p_idempotency_key),''); v_hash text; v_idem public.financial_idempotency_keys%rowtype; v_contributed bigint; v_settlement bigint;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  select m.kuri_id,m.id,me.status,me.refund_policy,me.reason,me.death_date_verified_at into v_kuri_id,v_membership_id,v_status,v_policy,v_reason,v_death_verified
  from public.membership_exits me join public.memberships m on m.id=me.membership_id where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to settle this exit.'; end if;
  v_hash:=encode(extensions.digest(jsonb_build_array(target_exit_id::text,settlement_payment_method::text,coalesce(btrim(settlement_reference),''),coalesce(settlement_date::text,''))::text,'sha256'),'hex');
  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'EXIT_SETTLE',v_key,v_hash) on conflict(actor_user_id,operation_type,idempotency_key) do nothing;
  select * into v_idem from public.financial_idempotency_keys where actor_user_id=v_actor and operation_type='EXIT_SETTLE' and idempotency_key=v_key for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different exit settlement.'; end if;
  if v_idem.status='COMPLETED' then return; end if;
  if v_status='SETTLED' then update public.financial_idempotency_keys set status='COMPLETED',result_reference_id=target_exit_id,completed_at=now() where id=v_idem.id; return; end if;
  if v_status<>'APPROVED' then raise exception 'Exit must be approved before settlement.'; end if;
  if v_reason='DEATH' and v_death_verified is null then raise exception 'Verify the death date before settling the death case.'; end if;
  if settlement_payment_method='PAID_IN_ADVANCE' then raise exception 'Use the refund payment action to record an immediate refund.'; end if;
  if v_policy='IMMEDIATE' then raise exception 'Immediate refunds must be settled through the refund transaction action.'; end if;
  select contributed_amount,settlement_amount into v_contributed,v_settlement from public.calculate_membership_exit_financials(target_exit_id);
  update public.membership_exits set amount_contributed=greatest(v_contributed,0),refund_amount=greatest(v_settlement,0),settled_at=coalesce(settlement_date,now()),
    notes=concat_ws(' | ',notes,'Settled without immediate cash refund: '||coalesce(btrim(settlement_reference),'')),status='SETTLED'
  where id=target_exit_id and status='APPROVED';
  update public.memberships set status='EXITED',exited_at=coalesce(exited_at,coalesce(settlement_date,now())) where id=v_membership_id;
  update public.financial_idempotency_keys set status='COMPLETED',result_reference_id=target_exit_id,completed_at=now() where id=v_idem.id;
end $$;

create or replace function public.record_death_settlement_for_admin(
  target_exit_id uuid,target_nominee_id uuid default null,p_settlement_notes text default null,p_idempotency_key text default null
) returns void language plpgsql security definer set search_path=''
as $$
declare
  v_actor uuid:=auth.uid(); v_key text:=nullif(btrim(p_idempotency_key),''); v_hash text; v_idem public.financial_idempotency_keys%rowtype;
  v_kuri_id uuid; v_membership_id uuid; v_person_id uuid; v_status public.settlement_status; v_paid bigint; v_refund bigint; v_remaining bigint;
  v_nominee_name text; v_contributed bigint; v_settlement bigint; v_notes text:=nullif(btrim(p_settlement_notes),'');
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  select m.kuri_id,m.id,m.person_id,me.status into v_kuri_id,v_membership_id,v_person_id,v_status
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id and me.reason='DEATH' for update of me,m;
  if v_kuri_id is null then raise exception 'Death exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to settle this death case.'; end if;
  v_hash:=encode(extensions.digest(jsonb_build_array(target_exit_id::text,target_nominee_id::text,coalesce(v_notes,''))::text,'sha256'),'hex');
  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'DEATH_SETTLEMENT',v_key,v_hash) on conflict(actor_user_id,operation_type,idempotency_key) do nothing;
  select * into v_idem from public.financial_idempotency_keys where actor_user_id=v_actor and operation_type='DEATH_SETTLEMENT' and idempotency_key=v_key for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different death settlement.'; end if;
  if v_idem.status='COMPLETED' then return; end if;
  if v_status='SETTLED' then update public.financial_idempotency_keys set status='COMPLETED',result_reference_id=target_exit_id,completed_at=now() where id=v_idem.id; return; end if;
  if v_status<>'APPROVED' then raise exception 'Death exit must be approved before settlement.'; end if;
  if not exists(select 1 from public.membership_exits where id=target_exit_id and death_date_verified_at is not null) then raise exception 'Verify the death date before settling the death case.'; end if;
  if target_nominee_id is null then raise exception 'A nominee must be selected before settlement.'; end if;
  if not exists(select 1 from public.nominees n where n.id=target_nominee_id and n.person_id=v_person_id) then raise exception 'Selected nominee does not belong to this person.'; end if;
  select contributed_amount,settlement_amount into v_contributed,v_settlement from public.calculate_membership_exit_financials(target_exit_id);
  v_refund:=greatest(v_settlement,0);
  select coalesce(sum(rt.amount),0) into v_paid from public.membership_exit_refund_transactions rt where rt.membership_exit_id=target_exit_id;
  v_remaining:=greatest(v_refund-v_paid,0);
  select n.name into v_nominee_name from public.nominees n where n.id=target_nominee_id;
  if v_remaining>0 then
    insert into public.membership_exit_refund_transactions(membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes)
    values(target_exit_id,v_remaining,'OTHER',null,now(),(select id from public.users where id=v_actor),'Death settlement refund to nominee: '||coalesce(v_nominee_name,'Nominee'));
  end if;
  update public.membership_exits set amount_contributed=greatest(v_contributed,0),refund_amount=v_refund,settled_to_nominee_id=target_nominee_id,settlement_notes=v_notes,settled_at=now(),status='SETTLED'
  where id=target_exit_id and status='APPROVED';
  update public.memberships set status='EXITED',exited_at=coalesce(exited_at,now()) where id=v_membership_id;
  update public.financial_idempotency_keys set status='COMPLETED',result_reference_id=target_exit_id,completed_at=now() where id=v_idem.id;
end $$;

create or replace function public.refresh_membership_exit_financials_for_admin(target_exit_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_kuri_id uuid; v_status public.settlement_status; v_contributed bigint; v_settlement bigint;
begin
  select m.kuri_id,me.status into v_kuri_id,v_status from public.membership_exits me join public.memberships m on m.id=me.membership_id where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to refresh this exit settlement.'; end if;
  if v_status in ('SETTLED','CANCELLED') then return; end if;
  select contributed_amount,settlement_amount into v_contributed,v_settlement from public.calculate_membership_exit_financials(target_exit_id);
  update public.membership_exits set amount_contributed=greatest(coalesce(v_contributed,0),0),refund_amount=greatest(coalesce(v_settlement,0),0) where id=target_exit_id and status in ('PENDING','APPROVED');
end $$;

create or replace function public.cancel_membership_exit_for_admin(target_exit_id uuid,cancellation_reason text default null)
returns public.settlement_status language plpgsql security definer set search_path=''
as $$
declare v_actor uuid:=auth.uid(); v_kuri_id uuid; v_status public.settlement_status; v_reason public.settlement_reason; v_paid bigint;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  select m.kuri_id,me.status,me.reason into v_kuri_id,v_status,v_reason from public.membership_exits me join public.memberships m on m.id=me.membership_id where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then raise exception 'You do not have permission to cancel this exit.'; end if;
  if v_status='CANCELLED' then return 'CANCELLED'; end if;
  if v_status='SETTLED' then raise exception 'Settled exits are terminal and cannot be cancelled.'; end if;
  if v_status='APPROVED' and v_reason='DEATH' then raise exception 'Approved death exits cannot be cancelled through the ordinary exit-cancellation action.'; end if;
  select coalesce(sum(rt.amount),0) into v_paid from public.membership_exit_refund_transactions rt where rt.membership_exit_id=target_exit_id;
  if v_paid>0 then raise exception 'An exit with an executed refund cannot be cancelled.'; end if;
  update public.membership_exits set status='CANCELLED',notes=case when nullif(btrim(cancellation_reason),'') is null then notes when notes is null then 'Cancelled: '||btrim(cancellation_reason) else notes||' | Cancelled: '||btrim(cancellation_reason) end where id=target_exit_id and status in ('PENDING','APPROVED');
  if not found then raise exception 'Exit is no longer cancellable.'; end if;
  perform public.sync_expense_obligations_for_membership((select membership_id from public.membership_exits where id=target_exit_id));
  return 'CANCELLED';
end $$;

commit;