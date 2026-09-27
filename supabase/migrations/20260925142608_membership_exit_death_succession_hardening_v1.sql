begin;

-- Exit, death and succession hardening.
-- Pending exits remain operational; settlement is separate.
-- Kuri authority replaces direct organization authority.
-- Financial contribution snapshots use effective payment allocation values.
-- Death verification is separate from death settlement.
-- Succession preserves the membership number and original person history.

alter table public.nominees
  add column if not exists successor_person_id uuid
    references public.people(id) on delete restrict;

alter table public.membership_exits
  add column if not exists death_date date;

create index if not exists nominees_successor_person_id_idx
  on public.nominees(successor_person_id);

create index if not exists membership_exits_membership_status_idx
  on public.membership_exits(membership_id,status);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.membership_exits'::regclass
      and conname='membership_exits_death_metadata_check'
  ) then
    alter table public.membership_exits
      add constraint membership_exits_death_metadata_check
      check (
        reason='DEATH'
        or (
          death_date is null
          and death_date_verified_at is null
          and death_date_verified_by is null
        )
      );
  end if;
end
$$;

drop function if exists public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text);
drop function if exists public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text);
drop function if exists public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz);
drop function if exists public.record_death_settlement_for_admin(uuid,uuid,text);
drop function if exists public.verify_death_date_for_admin(uuid,date,text);

create or replace function public.create_membership_exit_for_admin(
  target_membership_id uuid,
  exit_reason public.settlement_reason,
  target_exit_date date,
  target_refund_policy public.refund_policy default 'AT_MATURITY',
  target_refund_amount bigint default null,
  target_notes text default null,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_actor uuid := (select auth.uid());
  v_key text := nullif(btrim(p_idempotency_key),'');
  v_hash text;
  v_idem public.financial_idempotency_keys%rowtype;
  v_kuri_id uuid;
  v_status public.membership_status;
  v_contributed bigint := 0;
  v_refund bigint;
  v_exit_id uuid;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  if target_exit_date is null then raise exception 'Exit date is required.'; end if;
  if target_refund_amount is not null and target_refund_amount<0 then raise exception 'Refund amount cannot be negative.'; end if;

  select m.kuri_id,m.status into v_kuri_id,v_status
  from public.memberships m
  where m.id=target_membership_id
    and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update;

  if v_kuri_id is null then raise exception 'Membership not found or access denied.'; end if;
  if v_status not in ('ACTIVE','SUSPENDED') then raise exception 'Only ACTIVE or SUSPENDED memberships can be exited.'; end if;

  v_hash:=encode(extensions.digest(
    jsonb_build_object(
      'membership_id',target_membership_id::text,
      'reason',exit_reason::text,
      'exit_date',target_exit_date::text,
      'refund_policy',target_refund_policy::text,
      'refund_amount',coalesce(target_refund_amount::text,''),
      'notes',coalesce(target_notes,'')
    )::text,'sha256'),'hex');

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'MEMBERSHIP_EXIT_CREATE',v_key,v_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into v_idem
  from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor and f.operation_type='MEMBERSHIP_EXIT_CREATE' and f.idempotency_key=v_key
  for update;

  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different exit request.'; end if;
  if v_idem.status='COMPLETED' then return v_idem.result_reference_id; end if;

  if exists (
    select 1 from public.membership_exits me
    where me.membership_id=target_membership_id and me.status in ('PENDING','APPROVED')
  ) then
    raise exception 'An active exit record already exists for this membership.';
  end if;

  select coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) into v_contributed
  from public.payment_allocations pa
  join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=target_membership_id and pay.status='APPROVED' and pay.kuri_id=v_kuri_id;

  v_refund:=case when target_refund_amount is null then v_contributed else least(target_refund_amount,v_contributed) end;

  insert into public.membership_exits(
    membership_id,reason,exit_date,refund_policy,amount_contributed,refund_amount,status,requested_at,notes
  )
  values(
    target_membership_id,exit_reason,target_exit_date,target_refund_policy,
    v_contributed,v_refund,'PENDING',now(),nullif(btrim(target_notes),'')
  )
  returning id into v_exit_id;

  update public.financial_idempotency_keys
  set status='COMPLETED',result_reference_id=v_exit_id,completed_at=now()
  where id=v_idem.id;

  return v_exit_id;
end
$function$;

create or replace function public.list_membership_exits_for_admin(target_kuri_id uuid)
returns table(
  exit_id uuid,membership_id uuid,membership_number text,registered_name text,display_name text,
  reason public.settlement_reason,exit_date date,refund_policy public.refund_policy,
  amount_contributed bigint,refund_amount bigint,status public.settlement_status,
  approved_by uuid,settled_at timestamptz,notes text
)
language sql stable security definer set search_path=''
as $function$
  select me.id,m.id,m.membership_number,p.registered_name,p.display_name,
         me.reason,me.exit_date,me.refund_policy,me.amount_contributed,
         me.refund_amount,me.status,me.approved_by,me.settled_at,me.notes
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.people p on p.id=m.person_id
  where m.kuri_id=target_kuri_id
    and public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by me.exit_date desc,m.membership_number;
$function$;

create or replace function public.get_membership_exit_membership_id_for_admin(target_exit_id uuid)
returns uuid language sql stable security definer set search_path=''
as $function$
  select me.membership_id
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id
    and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

create or replace function public.get_membership_exit_reconciliation_for_admin(target_exit_id uuid)
returns table(
  exit_id uuid,membership_id uuid,kuri_id uuid,kuri_name text,membership_number text,
  registered_name text,display_name text,reason public.settlement_reason,
  refund_policy public.refund_policy,amount_contributed bigint,refund_amount bigint,
  exit_status public.settlement_status,paid_refund_amount bigint,refund_balance bigint,
  refund_payment_id uuid,refund_payment_method public.payment_method,
  refund_payment_reference text,refund_paid_at timestamptz
)
language sql stable security definer set search_path=''
as $function$
  select me.id,m.id,k.id,k.name,m.membership_number,p.registered_name,p.display_name,
         me.reason,me.refund_policy,me.amount_contributed,me.refund_amount,me.status,
         coalesce(rt.amount,0),greatest(me.refund_amount-coalesce(rt.amount,0),0),
         rt.id,rt.payment_method,rt.payment_reference,rt.paid_at
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  join public.people p on p.id=m.person_id
  left join public.membership_exit_refund_transactions rt on rt.membership_exit_id=me.id
  where me.id=target_exit_id
    and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;

create or replace function public.approve_membership_exit_for_admin(target_exit_id uuid)
returns void language plpgsql security definer set search_path=''
as $function$
declare v_kuri_id uuid; v_membership_id uuid; v_status public.settlement_status; v_contributed bigint:=0;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select m.kuri_id,me.membership_id,me.status into v_kuri_id,v_membership_id,v_status
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to approve this exit.';
  end if;
  if v_status='APPROVED' then return; end if;
  if v_status<>'PENDING' then raise exception 'Exit is not pending approval.'; end if;

  select coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) into v_contributed
  from public.payment_allocations pa join public.payments pay on pay.id=pa.payment_id
  join public.installments i on i.id=pa.installment_id
  where i.membership_id=v_membership_id and pay.status='APPROVED' and pay.kuri_id=v_kuri_id;

  update public.membership_exits
  set amount_contributed=v_contributed,refund_amount=least(coalesce(refund_amount,0),v_contributed),
      approved_by=(select id from public.users where id=auth.uid())
  where id=target_exit_id and status='PENDING';
  if not found then raise exception 'Exit is no longer pending.'; end if;
  perform public.transition_membership_exit_status_for_admin(target_exit_id,'APPROVED');
end
$function$;

create or replace function public.transition_membership_exit_status_for_admin(
  target_exit_id uuid,target_status public.settlement_status
)
returns public.settlement_status language plpgsql security definer set search_path=''
as $function$
declare v_status public.settlement_status; v_kuri_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select me.status,m.kuri_id into v_status,v_kuri_id
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Membership exit not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to change this exit status.';
  end if;
  if v_status=target_status then return v_status; end if;
  if not (
    (v_status='PENDING' and target_status in ('APPROVED','CANCELLED'))
    or (v_status='APPROVED' and target_status in ('SETTLED','CANCELLED'))
  ) then
    raise exception 'Invalid membership exit transition: % -> %.',v_status,target_status;
  end if;
  update public.membership_exits
  set status=target_status,
      settled_at=case when target_status='SETTLED' then coalesce(settled_at,now()) else settled_at end
  where id=target_exit_id;
  return target_status;
end
$function$;

create or replace function public.record_membership_exit_refund_for_admin(
  target_exit_id uuid,refund_amount bigint,refund_payment_method public.payment_method,
  refund_reference text default null,refund_paid_at timestamptz default null,
  refund_notes text default null,p_idempotency_key text default null
)
returns uuid language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid:=(select auth.uid()); v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text; v_idem public.financial_idempotency_keys%rowtype;
  v_kuri_id uuid; v_expected bigint; v_existing bigint:=0; v_tx_id uuid; v_membership_id uuid;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  if refund_amount is null or refund_amount<=0 then raise exception 'Refund amount must be greater than zero.'; end if;

  select m.kuri_id,me.refund_amount,me.membership_id into v_kuri_id,v_expected,v_membership_id
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id for update;
  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to record this refund.';
  end if;
  if not exists(
    select 1 from public.membership_exits me
    where me.id=target_exit_id and me.status='APPROVED' and me.refund_policy='IMMEDIATE'
  ) then raise exception 'Only approved immediate refunds can be paid here.'; end if;

  v_hash:=encode(extensions.digest(
    jsonb_build_object(
      'exit_id',target_exit_id::text,'refund_amount',refund_amount,
      'payment_method',refund_payment_method::text,'reference',coalesce(refund_reference,''),
      'paid_at',coalesce(refund_paid_at::text,''),'notes',coalesce(refund_notes,'')
    )::text,'sha256'),'hex');

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'MEMBERSHIP_EXIT_REFUND',v_key,v_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into v_idem from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor and f.operation_type='MEMBERSHIP_EXIT_REFUND' and f.idempotency_key=v_key
  for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different refund request.'; end if;
  if v_idem.status='COMPLETED' then return v_idem.result_reference_id; end if;

  select coalesce(sum(rt.amount),0) into v_existing
  from public.membership_exit_refund_transactions rt
  where rt.membership_exit_id=target_exit_id for update;
  if v_existing>0 then raise exception 'A refund transaction already exists for this exit.'; end if;
  if refund_amount>v_expected then raise exception 'Refund exceeds the approved refund amount.'; end if;

  insert into public.membership_exit_refund_transactions(
    membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
  )
  values(
    target_exit_id,refund_amount,refund_payment_method,nullif(btrim(refund_reference),''),
    coalesce(refund_paid_at,now()),(select id from public.users where id=v_actor),
    nullif(btrim(refund_notes),'')
  )
  returning id into v_tx_id;

  if refund_amount=v_expected then
    perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');
    perform public.transition_membership_status_for_admin(v_membership_id,'EXITED');
  end if;

  update public.financial_idempotency_keys
  set status='COMPLETED',result_reference_id=v_tx_id,completed_at=now()
  where id=v_idem.id;
  return v_tx_id;
end
$function$;

create or replace function public.verify_death_date_for_admin(
  target_exit_id uuid,verified_death_date date,verification_notes text default null
)
returns date language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid:=(select auth.uid()); v_kuri_id uuid; v_exit_date date;
  v_reason public.settlement_reason; v_status public.settlement_status; v_existing date;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if verified_death_date is null or verified_death_date>current_date then
    raise exception 'Verified death date must not be in the future.';
  end if;

  select m.kuri_id,me.exit_date,me.reason,me.status,me.death_date
    into v_kuri_id,v_exit_date,v_reason,v_status,v_existing
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id for update;

  if v_kuri_id is null or v_reason<>'DEATH' then raise exception 'Death exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to verify this death case.';
  end if;
  if v_status not in ('PENDING','APPROVED') then raise exception 'Death date cannot be verified for this exit state.'; end if;
  if verified_death_date>v_exit_date then raise exception 'Death date cannot be after the exit date.'; end if;
  if v_existing is not null and v_existing<>verified_death_date then raise exception 'Verified death date is immutable once recorded.'; end if;

  update public.membership_exits
  set death_date=verified_death_date,
      death_date_verified_at=coalesce(death_date_verified_at,now()),
      death_date_verified_by=coalesce(death_date_verified_by,(select id from public.users where id=v_actor)),
      notes=case
        when nullif(btrim(verification_notes),'') is null then notes
        when notes is null then 'Death date verification: '||btrim(verification_notes)
        else notes||' | Death date verification: '||btrim(verification_notes)
      end
  where id=target_exit_id;

  return verified_death_date;
end
$function$;

create or replace function public.get_death_settlement_context_for_admin(target_membership_id uuid)
returns table(
  membership_id uuid,membership_number text,person_id uuid,registered_name text,display_name text,
  nominee_id uuid,nominee_name text,nominee_relationship text,nominee_phone text,nominee_address text,
  nominee_notes text,refund_policy public.refund_policy,amount_contributed bigint,refund_amount bigint,
  exit_status public.settlement_status,exit_date date,settled_to_nominee_id uuid,settlement_notes text
)
language sql stable security definer set search_path=''
as $function$
  select m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
         n.id,n.name,n.relationship,n.phone,n.address,n.notes,
         me.refund_policy,me.amount_contributed,me.refund_amount,me.status,
         me.exit_date,me.settled_to_nominee_id,me.settlement_notes
  from public.memberships m
  join public.people p on p.id=m.person_id
  join public.membership_exits me on me.membership_id=m.id
  left join public.nominees n on n.person_id=m.person_id
    and (me.settled_to_nominee_id is null or n.id=me.settled_to_nominee_id)
  where m.id=target_membership_id and me.reason='DEATH' and me.status<>'CANCELLED'
    and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by n.name,n.id;
$function$;

create or replace function public.record_death_settlement_for_admin(
  target_exit_id uuid,target_nominee_id uuid default null,
  p_settlement_notes text default null,p_idempotency_key text default null
)
returns void language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid:=(select auth.uid()); v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text; v_idem public.financial_idempotency_keys%rowtype;
  v_kuri_id uuid; v_membership_id uuid; v_person_id uuid; v_refund bigint:=0;
  v_status public.settlement_status;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;

  select m.kuri_id,m.id,m.person_id,coalesce(me.refund_amount,0),me.status
    into v_kuri_id,v_membership_id,v_person_id,v_refund,v_status
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id and me.reason='DEATH' for update;

  if v_kuri_id is null then raise exception 'Death exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to settle this death case.';
  end if;
  if v_status<>'APPROVED' then raise exception 'Death exit must be approved before settlement.'; end if;
  if (select death_date_verified_at from public.membership_exits where id=target_exit_id) is null then
    raise exception 'Death date must be verified before settlement.';
  end if;
  if target_nominee_id is null then raise exception 'A nominee must be selected before settlement.'; end if;
  if not exists(select 1 from public.nominees n where n.id=target_nominee_id and n.person_id=v_person_id) then
    raise exception 'Selected nominee does not belong to this person.';
  end if;

  v_hash:=encode(extensions.digest(
    jsonb_build_object('exit_id',target_exit_id::text,'nominee_id',target_nominee_id::text,'notes',coalesce(p_settlement_notes,''))::text,
    'sha256'),'hex');

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'DEATH_SETTLEMENT',v_key,v_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into v_idem from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor and f.operation_type='DEATH_SETTLEMENT' and f.idempotency_key=v_key
  for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different death settlement.'; end if;
  if v_idem.status='COMPLETED' then return; end if;

  if v_refund>0 and exists(
    select 1 from public.membership_exit_refund_transactions rt where rt.membership_exit_id=target_exit_id
  ) then raise exception 'A refund transaction already exists for this death exit.'; end if;

  if v_refund>0 then
    insert into public.membership_exit_refund_transactions(
      membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
    )
    values(
      target_exit_id,v_refund,'OTHER',null,now(),(select id from public.users where id=v_actor),
      'Death settlement refund to nominee: '||coalesce((select n.name from public.nominees n where n.id=target_nominee_id),'Nominee')
    );
  end if;

  update public.membership_exits
  set settled_to_nominee_id=target_nominee_id,
      settlement_notes=nullif(btrim(p_settlement_notes),''),
      settled_at=now()
  where id=target_exit_id;

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');
  perform public.transition_membership_status_for_admin(v_membership_id,'EXITED');

  update public.financial_idempotency_keys
  set status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
  where id=v_idem.id;
end
$function$;

create or replace function public.settle_membership_exit_for_admin(
  target_exit_id uuid,
  settlement_payment_method public.muppu_settlement_method default 'PAID_IN_ADVANCE',
  settlement_reference text default null,
  settlement_date timestamptz default null,
  p_idempotency_key text default null
)
returns void language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid:=(select auth.uid()); v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text; v_idem public.financial_idempotency_keys%rowtype;
  v_kuri_id uuid; v_membership_id uuid; v_status public.settlement_status;
  v_policy public.refund_policy; v_reason public.settlement_reason; v_death_verified timestamptz;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;

  select m.kuri_id,m.id,me.status,me.refund_policy,me.reason,me.death_date_verified_at
    into v_kuri_id,v_membership_id,v_status,v_policy,v_reason,v_death_verified
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id for update;

  if v_kuri_id is null then raise exception 'Exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to settle this exit.';
  end if;
  if v_status='SETTLED' then return; end if;
  if v_status<>'APPROVED' then raise exception 'Exit must be approved before settlement.'; end if;
  if v_policy='IMMEDIATE' then raise exception 'Immediate refunds must be settled through the refund transaction action.'; end if;
  if v_reason='DEATH' and v_death_verified is null then raise exception 'Death date must be verified before settlement.'; end if;
  if settlement_payment_method='PAID_IN_ADVANCE' then raise exception 'Use the refund payment action to record an immediate refund.'; end if;
  if settlement_date is not null and settlement_date>now() then raise exception 'Settlement date cannot be in the future.'; end if;

  v_hash:=encode(extensions.digest(
    jsonb_build_object(
      'exit_id',target_exit_id::text,'method',settlement_payment_method::text,
      'reference',coalesce(settlement_reference,''),'date',coalesce(settlement_date::text,'')
    )::text,'sha256'),'hex');

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'MEMBERSHIP_EXIT_SETTLE',v_key,v_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into v_idem from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor and f.operation_type='MEMBERSHIP_EXIT_SETTLE' and f.idempotency_key=v_key
  for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different exit settlement.'; end if;
  if v_idem.status='COMPLETED' then return; end if;

  update public.membership_exits
  set notes=concat_ws(' | ',notes,'Settled: '||coalesce(settlement_reference,'')),
      settled_at=coalesce(settlement_date,now())
  where id=target_exit_id and status='APPROVED';
  if not found then raise exception 'Exit is no longer approved.'; end if;

  perform public.transition_membership_exit_status_for_admin(target_exit_id,'SETTLED');
  perform public.transition_membership_status_for_admin(v_membership_id,'EXITED');

  update public.financial_idempotency_keys
  set status='COMPLETED',result_reference_id=target_exit_id,completed_at=now()
  where id=v_idem.id;
end
$function$;

create or replace function public.create_nominee_for_admin(
  target_person_id uuid,nominee_name text,nominee_relationship text default null,
  nominee_phone text default null,nominee_address text default null,nominee_notes text default null
)
returns uuid language plpgsql security definer set search_path=''
as $function$
declare v_nominee_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if nullif(btrim(nominee_name),'') is null then raise exception 'Nominee name is required.'; end if;
  if not exists(
    select 1 from public.memberships m
    where m.person_id=target_person_id
      and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ) then raise exception 'Person not found or access denied.'; end if;
  insert into public.nominees(person_id,name,relationship,phone,address,notes)
  values(
    target_person_id,nullif(btrim(nominee_name),''),
    nullif(btrim(nominee_relationship),''),nullif(btrim(nominee_phone),''),
    nullif(btrim(nominee_address),''),nullif(btrim(nominee_notes),'')
  )
  returning id into v_nominee_id;
  return v_nominee_id;
end
$function$;

create or replace function public.update_nominee_for_admin(
  target_nominee_id uuid,nominee_name text,nominee_relationship text default null,
  nominee_phone text default null,nominee_address text default null,nominee_notes text default null
)
returns void language plpgsql security definer set search_path=''
as $function$
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if nullif(btrim(nominee_name),'') is null then raise exception 'Nominee name is required.'; end if;
  if not exists(
    select 1 from public.nominees n join public.memberships m on m.person_id=n.person_id
    where n.id=target_nominee_id
      and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ) then raise exception 'Nominee not found or access denied.'; end if;
  update public.nominees
  set name=nullif(btrim(nominee_name),''),relationship=nullif(btrim(nominee_relationship),''),
      phone=nullif(btrim(nominee_phone),''),address=nullif(btrim(nominee_address),''),
      notes=nullif(btrim(nominee_notes),'')
  where id=target_nominee_id;
end
$function$;

create or replace function public.delete_nominee_for_admin(target_nominee_id uuid)
returns void language plpgsql security definer set search_path=''
as $function$
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if not exists(
    select 1 from public.nominees n join public.memberships m on m.person_id=n.person_id
    where n.id=target_nominee_id
      and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ) then raise exception 'Nominee not found or access denied.'; end if;
  if exists(select 1 from public.membership_exits me where me.settled_to_nominee_id=target_nominee_id)
     or exists(select 1 from public.membership_successions s where s.nominee_id=target_nominee_id) then
    raise exception 'A nominee used in a settlement or succession cannot be deleted.';
  end if;
  delete from public.nominees where id=target_nominee_id;
end
$function$;

create or replace function public.list_nominees_for_admin(target_person_id uuid)
returns table(id uuid,person_id uuid,name text,relationship text,phone text,address text,notes text)
language sql stable security definer set search_path=''
as $function$
  select n.id,n.person_id,n.name,n.relationship,n.phone,n.address,n.notes
  from public.nominees n
  where n.person_id=target_person_id
    and exists(
      select 1 from public.memberships m
      where m.person_id=target_person_id
        and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
    )
  order by n.name,n.id;
$function$;

create or replace function public.get_membership_nominees_for_admin(target_membership_id uuid)
returns table(
  membership_id uuid,membership_number text,person_id uuid,registered_name text,display_name text,
  nominee_id uuid,nominee_name text,nominee_relationship text,nominee_phone text,
  nominee_address text,nominee_notes text
)
language sql stable security definer set search_path=''
as $function$
  select m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
         n.id,n.name,n.relationship,n.phone,n.address,n.notes
  from public.memberships m
  join public.people p on p.id=m.person_id
  left join public.nominees n on n.person_id=m.person_id
  where m.id=target_membership_id
    and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  order by n.name,n.id;
$function$;

create or replace function public.enforce_nominee_successor_identity()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare v_person_org uuid; v_successor_org uuid;
begin
  if new.successor_person_id is null then return new; end if;
  select p.organization_id into v_person_org from public.people p where p.id=new.person_id;
  select p.organization_id into v_successor_org from public.people p where p.id=new.successor_person_id;
  if new.person_id=new.successor_person_id then
    raise exception 'A nominee successor must differ from the original member.';
  end if;
  if v_person_org is null or v_successor_org is null or v_person_org<>v_successor_org then
    raise exception 'Nominee successor must belong to the same organization.';
  end if;
  return new;
end
$function$;

drop trigger if exists nominees_successor_identity_guard on public.nominees;
create trigger nominees_successor_identity_guard
before insert or update of successor_person_id on public.nominees
for each row execute function public.enforce_nominee_successor_identity();

create or replace function public.link_nominee_to_successor_person_for_admin(
  target_membership_id uuid,target_nominee_id uuid,target_successor_person_id uuid
)
returns void language plpgsql security definer set search_path=''
as $function$
declare v_kuri_id uuid; v_org_id uuid; v_original_person_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select m.kuri_id,m.person_id,k.organization_id into v_kuri_id,v_original_person_id,v_org_id
  from public.memberships m join public.kuris k on k.id=m.kuri_id
  where m.id=target_membership_id
    and public.has_kuri_admin_role(m.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update;
  if v_kuri_id is null then raise exception 'Membership not found or access denied.'; end if;
  if target_successor_person_id=v_original_person_id then raise exception 'Successor must differ from the original member.'; end if;
  if not exists(
    select 1 from public.people p where p.id=target_successor_person_id and p.organization_id=v_org_id
  ) then raise exception 'Successor person must belong to the Kuri organization.'; end if;
  if not exists(
    select 1 from public.nominees n where n.id=target_nominee_id and n.person_id=v_original_person_id
  ) then raise exception 'Nominee not found for this membership.'; end if;
  update public.nominees set successor_person_id=target_successor_person_id where id=target_nominee_id;
end
$function$;

create or replace function public.enforce_membership_succession_identity()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare
  v_kuri_id uuid; v_original_person_id uuid; v_org_id uuid;
  v_original_org_id uuid; v_successor_org_id uuid;
  v_nominee_person_id uuid; v_nominee_successor_person_id uuid;
begin
  select m.kuri_id,m.person_id,k.organization_id into v_kuri_id,v_original_person_id,v_org_id
  from public.memberships m join public.kuris k on k.id=m.kuri_id
  where m.id=new.membership_id for update;
  if v_kuri_id is null then raise exception 'Membership for succession was not found.'; end if;

  select p.organization_id into v_original_org_id from public.people p where p.id=new.original_person_id;
  select p.organization_id into v_successor_org_id from public.people p where p.id=new.successor_person_id;
  select n.person_id,n.successor_person_id into v_nominee_person_id,v_nominee_successor_person_id
  from public.nominees n where n.id=new.nominee_id;

  if new.original_person_id<>v_original_person_id then raise exception 'Succession original person does not match the membership history.'; end if;
  if new.successor_person_id=new.original_person_id then raise exception 'A member cannot succeed themselves.'; end if;
  if v_original_org_id is distinct from v_org_id or v_successor_org_id is distinct from v_org_id then
    raise exception 'Succession identities must belong to the Kuri organization.';
  end if;
  if v_nominee_person_id is distinct from v_original_person_id then
    raise exception 'The selected nominee is not registered for the original member.';
  end if;
  if v_nominee_successor_person_id is distinct from new.successor_person_id then
    raise exception 'The selected nominee is not linked to this successor person.';
  end if;
  if not exists(
    select 1 from public.membership_exits me
    where me.id=new.membership_exit_id and me.membership_id=new.membership_id
      and me.reason='DEATH' and me.status='SETTLED'
      and me.settled_to_nominee_id=new.nominee_id and me.death_date_verified_at is not null
  ) then
    raise exception 'Succession requires a settled, verified death case with the same nominee.';
  end if;
  return new;
end
$function$;

create or replace function public.record_membership_succession_for_admin(
  target_exit_id uuid,target_nominee_id uuid,succession_notes text default null
)
returns uuid language plpgsql security definer set search_path=''
as $function$
declare
  v_kuri_id uuid; v_membership_id uuid; v_original_person_id uuid;
  v_successor_person_id uuid; v_status public.settlement_status; v_succession_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select m.kuri_id,m.id,m.person_id,me.status into v_kuri_id,v_membership_id,v_original_person_id,v_status
  from public.membership_exits me join public.memberships m on m.id=me.membership_id
  where me.id=target_exit_id and me.reason='DEATH' for update;
  if v_kuri_id is null then raise exception 'Death exit record not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to record succession for this Kuri.';
  end if;
  if v_status<>'SETTLED' then raise exception 'Death settlement must be completed before succession.'; end if;
  if (select death_date_verified_at from public.membership_exits where id=target_exit_id) is null then
    raise exception 'Death date must be verified before succession.';
  end if;

  select n.successor_person_id into v_successor_person_id
  from public.nominees n where n.id=target_nominee_id and n.person_id=v_original_person_id;
  if v_successor_person_id is null then raise exception 'Selected nominee is not linked to a successor person.'; end if;
  if exists(select 1 from public.membership_successions s where s.membership_id=v_membership_id) then
    raise exception 'This membership already has a recorded succession.';
  end if;

  insert into public.membership_successions(
    membership_id,membership_exit_id,original_person_id,successor_person_id,nominee_id,recorded_by,notes
  )
  values(
    v_membership_id,target_exit_id,v_original_person_id,v_successor_person_id,target_nominee_id,
    (select id from public.users where id=auth.uid()),nullif(btrim(succession_notes),'')
  )
  returning id into v_succession_id;

  update public.memberships set current_holder_person_id=v_successor_person_id where id=v_membership_id;
  perform public.transition_membership_status_for_admin(v_membership_id,'ACTIVE');

  return v_succession_id;
end
$function$;

create or replace function public.transition_membership_status_for_admin(
  target_membership_id uuid,target_status public.membership_status
)
returns public.membership_status language plpgsql security definer set search_path=''
as $function$
declare v_current public.membership_status; v_kuri_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  select m.status,m.kuri_id into v_current,v_kuri_id from public.memberships m
  where m.id=target_membership_id for update;
  if v_kuri_id is null then raise exception 'Membership not found.'; end if;
  if not public.has_kuri_admin_role(v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to change this membership status.';
  end if;
  if v_current=target_status then return v_current; end if;

  if not (
    (v_current='PENDING' and target_status='ACTIVE')
    or (v_current='ACTIVE' and target_status in ('SUSPENDED','EXITED','COMPLETED','TRANSFERRED'))
    or (v_current='SUSPENDED' and target_status in ('ACTIVE','EXITED','COMPLETED','TRANSFERRED'))
    or (
      v_current='EXITED' and target_status='ACTIVE'
      and exists(
        select 1 from public.membership_successions s
        where s.membership_id=target_membership_id
          and s.successor_person_id=(select m.current_holder_person_id from public.memberships m where m.id=target_membership_id)
      )
    )
  ) then raise exception 'Invalid membership status transition: % -> %.',v_current,target_status; end if;

  update public.memberships
  set status=target_status,
      exited_at=case
        when target_status='EXITED' then coalesce(exited_at,now())
        when target_status='ACTIVE' and v_current='EXITED' then null
        else exited_at end,
      completed_at=case when target_status='COMPLETED' then coalesce(completed_at,now()) else completed_at end
  where id=target_membership_id;

  if target_status='ACTIVE' then
    perform public.sync_expense_obligations_for_membership(target_membership_id);
  end if;
  return target_status;
end
$function$;

revoke all on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text,text) from public,anon,authenticated;
revoke all on function public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text,text) from public,anon,authenticated;
revoke all on function public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz,text) from public,anon,authenticated;
revoke all on function public.record_death_settlement_for_admin(uuid,uuid,text,text) from public,anon,authenticated;
revoke all on function public.verify_death_date_for_admin(uuid,date,text) from public,anon,authenticated;

grant execute on function public.create_membership_exit_for_admin(uuid,public.settlement_reason,date,public.refund_policy,bigint,text,text) to authenticated;
grant execute on function public.list_membership_exits_for_admin(uuid) to authenticated;
grant execute on function public.get_membership_exit_membership_id_for_admin(uuid) to authenticated;
grant execute on function public.get_membership_exit_reconciliation_for_admin(uuid) to authenticated;
grant execute on function public.approve_membership_exit_for_admin(uuid) to authenticated;
grant execute on function public.transition_membership_exit_status_for_admin(uuid,public.settlement_status) to authenticated;
grant execute on function public.cancel_membership_exit_for_admin(uuid,text) to authenticated;
grant execute on function public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text,text) to authenticated;
grant execute on function public.verify_death_date_for_admin(uuid,date,text) to authenticated;
grant execute on function public.get_death_settlement_context_for_admin(uuid) to authenticated;
grant execute on function public.record_death_settlement_for_admin(uuid,uuid,text,text) to authenticated;
grant execute on function public.settle_membership_exit_for_admin(uuid,public.muppu_settlement_method,text,timestamptz,text) to authenticated;
grant execute on function public.create_nominee_for_admin(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.update_nominee_for_admin(uuid,text,text,text,text,text) to authenticated;
grant execute on function public.delete_nominee_for_admin(uuid) to authenticated;
grant execute on function public.list_nominees_for_admin(uuid) to authenticated;
grant execute on function public.get_membership_nominees_for_admin(uuid) to authenticated;
grant execute on function public.link_nominee_to_successor_person_for_admin(uuid,uuid,uuid) to authenticated;
grant execute on function public.record_membership_succession_for_admin(uuid,uuid,text) to authenticated;

revoke all on function public.enforce_nominee_successor_identity() from public,anon,authenticated;

commit;
