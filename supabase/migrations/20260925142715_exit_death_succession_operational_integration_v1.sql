begin;

-- Carry membership succession through operational domains.
-- A payment may be made by the historical member or the current holder.
-- Verified death cases are excluded from draw eligibility/finalization.
-- Future winner identity is the current holder while historical winner rows remain unchanged.
-- Expense generation stops after a pending/approved exit request.

create or replace function public.allocate_payment_for_admin(
  target_payment_id uuid,target_installment_id uuid,allocation_amount bigint,p_idempotency_key text
)
returns bigint language plpgsql security definer set search_path=''
as $function$
declare
  v_actor_user_id uuid := (select auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text; idem_row public.financial_idempotency_keys%rowtype;
  payment_person_id uuid; payment_total bigint; payment_status public.payment_status;
  payment_kuri_id uuid; installment_person_id uuid; membership_current_holder_id uuid;
  installment_amount_due bigint; target_kuri_id uuid; target_membership_id uuid;
  target_cycle_number integer; already_allocated bigint; installment_allocated bigint;
  next_paid bigint; earlier_outstanding bigint;
begin
  if v_actor_user_id is null then raise exception 'You must be signed in.'; end if;
  if normalized_key is null or char_length(normalized_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  if allocation_amount<=0 then raise exception 'Allocation amount must be greater than zero.'; end if;

  request_hash:=encode(extensions.digest(
    jsonb_build_array(target_payment_id::text,target_installment_id::text,allocation_amount::text)::text,'sha256'
  ),'hex');

  select p.person_id,p.status,p.kuri_id into payment_person_id,payment_status,payment_kuri_id
  from public.payments p where p.id=target_payment_id for update;
  if not found then raise exception 'Payment not found.'; end if;

  select i.amount_due,m.person_id,m.current_holder_person_id,m.id,c.kuri_id,c.cycle_number
    into installment_amount_due,installment_person_id,membership_current_holder_id,
         target_membership_id,target_kuri_id,target_cycle_number
  from public.installments i
  join public.memberships m on m.id=i.membership_id
  join public.cycles c on c.id=i.cycle_id
  where i.id=target_installment_id for update;
  if not found then raise exception 'Installment not found.'; end if;

  if payment_kuri_id<>target_kuri_id then raise exception 'Payment and installment belong to different Kuris.'; end if;
  if payment_person_id<>installment_person_id
     and (membership_current_holder_id is null or payment_person_id<>membership_current_holder_id) then
    raise exception 'Payment person does not match the original member or current holder.';
  end if;

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor_user_id,target_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into idem_row from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor_user_id and f.operation_type='PAYMENT_ALLOCATION' and f.idempotency_key=normalized_key
  for update;
  if idem_row.request_hash<>request_hash then raise exception 'Idempotency key was already used for a different allocation request.'; end if;
  if idem_row.status='COMPLETED' then return idem_row.result_bigint; end if;

  if not public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to allocate this payment.';
  end if;
  if payment_status<>'APPROVED' then raise exception 'Only approved payments can be allocated.'; end if;

  perform 1 from public.installments lock_i
  join public.cycles lock_c on lock_c.id=lock_i.cycle_id
  where lock_i.membership_id=target_membership_id
  order by lock_c.cycle_number,lock_i.id
  for update;

  select coalesce(sum(greatest(oi.amount_due-oi.effective_paid,0)),0) into earlier_outstanding
  from (
    select oi.id,oi.amount_due,
      least(coalesce((
        select sum(public.get_effective_payment_allocation_amount(pa.id))
        from public.payment_allocations pa where pa.installment_id=oi.id
      ),0),oi.amount_due) as effective_paid,oc.cycle_number
    from public.installments oi join public.cycles oc on oc.id=oi.cycle_id
    where oi.membership_id=target_membership_id
  ) oi
  where oi.cycle_number<target_cycle_number;

  if earlier_outstanding>0 then
    raise exception 'Cannot skip outstanding earlier installments. Allocate the oldest outstanding installment first.';
  end if;

  payment_total:=public.get_effective_payment_amount(target_payment_id);

  select coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) into already_allocated
  from public.payment_allocations pa where pa.payment_id=target_payment_id;

  select coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) into installment_allocated
  from public.payment_allocations pa where pa.installment_id=target_installment_id;

  if already_allocated+allocation_amount>payment_total then raise exception 'Allocation exceeds payment amount.'; end if;
  if installment_allocated>=installment_amount_due then raise exception 'Target installment is already fully paid.'; end if;
  if installment_allocated+allocation_amount>installment_amount_due then
    raise exception 'Allocation exceeds installment balance. Use the advance-payment allocation API to span multiple installments.';
  end if;

  insert into public.payment_allocations(payment_id,installment_id,amount,allocated_by)
  values(target_payment_id,target_installment_id,allocation_amount,(select id from public.users where id=v_actor_user_id))
  on conflict(payment_id,installment_id) do update
    set amount=public.payment_allocations.amount+excluded.amount,
        allocated_at=now(),allocated_by=excluded.allocated_by;

  select public.reconcile_installment_from_allocations(target_installment_id) into next_paid;

  update public.financial_idempotency_keys
  set status='COMPLETED',result_bigint=next_paid,completed_at=now()
  where id=idem_row.id;
  return next_paid;
end
$function$;

create or replace function public.allocate_payment_to_oldest_installments_for_admin(
  target_payment_id uuid,target_membership_id uuid,requested_allocation_amount bigint,p_idempotency_key text
)
returns bigint language plpgsql security definer set search_path=''
as $function$
declare
  v_actor_user_id uuid := (select auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text; idem_row public.financial_idempotency_keys%rowtype;
  payment_person_id uuid; payment_kuri_id uuid; payment_status public.payment_status;
  membership_person_id uuid; membership_current_holder_id uuid; membership_kuri_id uuid;
  effective_payment_amount bigint; already_allocated bigint; available_payment bigint;
  total_outstanding bigint; remaining bigint; chunk bigint;
  installment_allocated bigint; effective_installment_paid bigint;
  actor_db_user_id uuid; inst record; total_allocated bigint:=0;
begin
  if v_actor_user_id is null then raise exception 'You must be signed in.'; end if;
  if normalized_key is null or char_length(normalized_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  if requested_allocation_amount<=0 then raise exception 'Allocation amount must be greater than zero.'; end if;

  request_hash:=encode(extensions.digest(
    jsonb_build_array(target_payment_id::text,target_membership_id::text,requested_allocation_amount::text)::text,'sha256'
  ),'hex');

  select p.person_id,p.kuri_id,p.status into payment_person_id,payment_kuri_id,payment_status
  from public.payments p where p.id=target_payment_id for update;
  if not found then raise exception 'Payment not found.'; end if;

  select m.person_id,m.current_holder_person_id,m.kuri_id
    into membership_person_id,membership_current_holder_id,membership_kuri_id
  from public.memberships m where m.id=target_membership_id for update;
  if not found then raise exception 'Membership not found.'; end if;

  if payment_kuri_id<>membership_kuri_id then raise exception 'Payment and membership belong to different Kuris.'; end if;
  if payment_person_id<>membership_person_id
     and (membership_current_holder_id is null or payment_person_id<>membership_current_holder_id) then
    raise exception 'Payment person does not match the original member or current holder.';
  end if;
  if not public.has_kuri_admin_role(membership_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to allocate this payment.';
  end if;
  if payment_status<>'APPROVED' then raise exception 'Only approved payments can be allocated.'; end if;

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor_user_id,membership_kuri_id,'PAYMENT_ALLOCATION',normalized_key,request_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into idem_row from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor_user_id and f.operation_type='PAYMENT_ALLOCATION' and f.idempotency_key=normalized_key
  for update;
  if idem_row.request_hash<>request_hash then raise exception 'Idempotency key was already used for a different allocation request.'; end if;
  if idem_row.status='COMPLETED' then return idem_row.result_bigint; end if;

  actor_db_user_id:=(select id from public.users where id=v_actor_user_id);

  perform 1 from public.installments lock_i
  join public.cycles lock_c on lock_c.id=lock_i.cycle_id
  where lock_i.membership_id=target_membership_id
  order by lock_c.cycle_number,lock_i.id for update;

  effective_payment_amount:=public.get_effective_payment_amount(target_payment_id);
  select coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) into already_allocated
  from public.payment_allocations pa where pa.payment_id=target_payment_id;
  available_payment:=greatest(effective_payment_amount-already_allocated,0);

  if requested_allocation_amount>available_payment then raise exception 'Allocation exceeds the payment amount available for allocation.'; end if;

  select coalesce(sum(greatest(x.amount_due-x.effective_paid,0)),0) into total_outstanding
  from (
    select oi.amount_due,
      least(coalesce((
        select sum(public.get_effective_payment_allocation_amount(pa2.id))
        from public.payment_allocations pa2 where pa2.installment_id=oi.id
      ),0),oi.amount_due) as effective_paid
    from public.installments oi where oi.membership_id=target_membership_id
  ) x;

  if requested_allocation_amount>total_outstanding then
    raise exception 'Allocation exceeds the total outstanding installments for this membership.';
  end if;

  remaining:=requested_allocation_amount;
  for inst in
    select oi.id,oi.amount_due,oc.cycle_number
    from public.installments oi join public.cycles oc on oc.id=oi.cycle_id
    where oi.membership_id=target_membership_id
    order by oc.cycle_number,oi.id
  loop
    exit when remaining=0;
    select coalesce(sum(public.get_effective_payment_allocation_amount(pa.id)),0) into installment_allocated
    from public.payment_allocations pa where pa.installment_id=inst.id;
    effective_installment_paid:=least(installment_allocated,inst.amount_due);
    chunk:=least(remaining,greatest(inst.amount_due-effective_installment_paid,0));
    if chunk>0 then
      insert into public.payment_allocations(payment_id,installment_id,amount,allocated_by)
      values(target_payment_id,inst.id,chunk,actor_db_user_id)
      on conflict(payment_id,installment_id) do update
        set amount=public.payment_allocations.amount+excluded.amount,
            allocated_at=now(),allocated_by=excluded.allocated_by;
      perform public.reconcile_installment_from_allocations(inst.id);
      remaining:=remaining-chunk; total_allocated:=total_allocated+chunk;
    end if;
  end loop;

  if remaining<>0 then raise exception 'Unable to allocate the complete requested amount.'; end if;

  update public.financial_idempotency_keys
  set status='COMPLETED',result_bigint=total_allocated,completed_at=now()
  where id=idem_row.id;
  return total_allocated;
end
$function$;

create or replace function public.prepare_draw_for_admin(target_cycle_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $function$
declare
  session_id uuid; cycle_kuri_id uuid; cycle_status_value public.cycle_status;
  draw_status_value public.draw_status; actor_db_user_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select c.kuri_id,c.status into cycle_kuri_id,cycle_status_value
  from public.cycles c
  where c.id=target_cycle_id
    and public.has_kuri_admin_role(c.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update;

  if cycle_kuri_id is null then raise exception 'You do not have permission to manage this draw.'; end if;
  if cycle_status_value not in ('PAYMENT_CLOSED','DRAW_PENDING') then
    raise exception 'Cycle must be PAYMENT_CLOSED or DRAW_PENDING before preparing a draw.';
  end if;

  actor_db_user_id:=(select id from public.users where id=auth.uid());

  select d.id,d.status into session_id,draw_status_value
  from public.draw_sessions d
  where d.cycle_id=target_cycle_id and d.kuri_id=cycle_kuri_id for update;

  if session_id is null then
    insert into public.draw_sessions(kuri_id,cycle_id,conducted_by,status,started_at)
    values(cycle_kuri_id,target_cycle_id,actor_db_user_id,'DRAFT',now())
    on conflict(kuri_id,cycle_id) do nothing
    returning id,status into session_id,draw_status_value;

    if session_id is null then
      select d.id,d.status into session_id,draw_status_value
      from public.draw_sessions d
      where d.cycle_id=target_cycle_id and d.kuri_id=cycle_kuri_id for update;
    end if;
  end if;

  if session_id is null then raise exception 'Unable to create or resolve the draw session.'; end if;
  if draw_status_value not in ('DRAFT','POOL_READY') then
    raise exception 'Draw session is already finalized or otherwise unavailable for preparation.';
  end if;
  if draw_status_value='POOL_READY' then return session_id; end if;

  insert into public.draw_pool_entries(
    draw_session_id,membership_id,system_eligible,admin_included,override,override_reason,modified_by,modified_at
  )
  select session_id,m.id,
    (m.status='ACTIVE' and i.status in ('PAID','PAID_LATE')
      and not exists(
        select 1 from public.membership_exits me
        where me.membership_id=m.id and me.reason='DEATH'
          and me.death_date_verified_at is not null and me.death_date<=current_date
          and me.status in ('PENDING','APPROVED')
      )),
    (m.status='ACTIVE' and i.status in ('PAID','PAID_LATE')
      and not exists(
        select 1 from public.membership_exits me
        where me.membership_id=m.id and me.reason='DEATH'
          and me.death_date_verified_at is not null and me.death_date<=current_date
          and me.status in ('PENDING','APPROVED')
      )),
    false,null,actor_db_user_id,now()
  from public.memberships m
  join public.installments i on i.membership_id=m.id
  where i.cycle_id=target_cycle_id and m.kuri_id=cycle_kuri_id
  on conflict(draw_session_id,membership_id) do nothing;

  update public.draw_pool_entries e
  set system_eligible=(
        m.status='ACTIVE' and i.status in ('PAID','PAID_LATE')
        and not exists(
          select 1 from public.membership_exits me
          where me.membership_id=m.id and me.reason='DEATH'
            and me.death_date_verified_at is not null and me.death_date<=current_date
            and me.status in ('PENDING','APPROVED')
        )
      ),
      admin_included=case when e.override then e.admin_included else (
        m.status='ACTIVE' and i.status in ('PAID','PAID_LATE')
        and not exists(
          select 1 from public.membership_exits me
          where me.membership_id=m.id and me.reason='DEATH'
            and me.death_date_verified_at is not null and me.death_date<=current_date
            and me.status in ('PENDING','APPROVED')
        )
      ) end,
      modified_by=actor_db_user_id,modified_at=now()
  from public.memberships m
  join public.installments i on i.membership_id=m.id
  where e.draw_session_id=session_id and e.membership_id=m.id
    and i.cycle_id=target_cycle_id and m.kuri_id=cycle_kuri_id;

  delete from public.draw_selections where draw_session_id=session_id;
  perform public.transition_draw_status_for_admin(session_id,'POOL_READY');
  return session_id;
end
$function$;

create or replace function public.finalize_draw_for_admin(
  target_cycle_id uuid,final_membership_ids uuid[],p_idempotency_key text default null
)
returns integer language plpgsql security definer set search_path=''
as $function$
declare
  v_actor uuid:=(select auth.uid()); v_key text:=nullif(btrim(p_idempotency_key),'');
  v_hash text; v_idem public.financial_idempotency_keys%rowtype;
  v_session_id uuid; v_kuri_id uuid; v_cycle_status public.cycle_status; v_draw_status public.draw_status;
  v_winner_count integer; v_selected_count integer; v_selected_person_count integer;
  v_unwon_member_count integer; v_remaining_cycles integer; v_max_winners integer;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if final_membership_ids is null or cardinality(final_membership_ids)<1 then raise exception 'Select at least one winner.'; end if;
  if cardinality(final_membership_ids)<>cardinality(array(select distinct unnest(final_membership_ids))) then
    raise exception 'Duplicate winner memberships are not allowed.';
  end if;
  if v_key is null or char_length(v_key)>200 then raise exception 'A valid idempotency key is required.'; end if;

  select c.kuri_id into v_kuri_id from public.cycles c
  where c.id=target_cycle_id
    and public.has_kuri_admin_role(c.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
  if v_kuri_id is null then raise exception 'You do not have permission to manage this draw.'; end if;

  v_hash:=encode(extensions.digest(
    jsonb_build_object('cycle_id',target_cycle_id::text,'membership_ids',to_jsonb(final_membership_ids))::text,'sha256'
  ),'hex');

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor,v_kuri_id,'DRAW_FINALIZE',v_key,v_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into v_idem from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor and f.operation_type='DRAW_FINALIZE' and f.idempotency_key=v_key for update;
  if v_idem.request_hash<>v_hash then raise exception 'Idempotency key was already used for a different finalization request.'; end if;
  if v_idem.status='COMPLETED' then
    select count(*) into v_winner_count from public.monthly_winners where cycle_id=target_cycle_id;
    return v_winner_count;
  end if;

  select d.id,c.kuri_id,c.status,d.status into v_session_id,v_kuri_id,v_cycle_status,v_draw_status
  from public.draw_sessions d join public.cycles c on c.id=d.cycle_id
  where d.cycle_id=target_cycle_id
    and public.has_kuri_admin_role(c.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  for update of d,c;

  if v_session_id is null then raise exception 'Prepare and run the draw before finalizing winners.'; end if;
  perform 1 from public.kuris k where k.id=v_kuri_id for update;
  if v_cycle_status<>'DRAW_PENDING' then raise exception 'Cycle must be DRAW_PENDING before finalizing winners.'; end if;
  if v_draw_status<>'RESULTS_READY' then raise exception 'Draw must have RESULTS_READY status before finalizing winners.'; end if;
  if exists(select 1 from public.monthly_winners where cycle_id=target_cycle_id) then raise exception 'Winners are already finalized for this cycle.'; end if;

  select count(*) into v_selected_count from public.draw_selections s
  where s.draw_session_id=v_session_id and s.membership_id=any(final_membership_ids);
  if v_selected_count<>array_length(final_membership_ids,1) then raise exception 'Final winners must come from the current draw selections.'; end if;

  if exists(
    select 1 from public.memberships m join public.membership_exits me on me.membership_id=m.id
    where m.id=any(final_membership_ids) and me.reason='DEATH'
      and me.death_date_verified_at is not null and me.death_date<=current_date
      and me.status in ('PENDING','APPROVED')
  ) then
    raise exception 'A verified-deceased membership cannot be finalized as a winner.';
  end if;

  select count(distinct coalesce(m.current_holder_person_id,m.person_id)) into v_selected_person_count
  from public.memberships m where m.id=any(final_membership_ids);
  if v_selected_person_count<>array_length(final_membership_ids,1) then
    raise exception 'Only one winner per current holder can be finalized in a cycle.';
  end if;

  if exists(
    select 1 from public.memberships m
    where m.id=any(final_membership_ids) and (m.kuri_id<>v_kuri_id or m.status<>'ACTIVE')
  ) then
    raise exception 'A final winner must be an ACTIVE membership in the draw Kuri.';
  end if;

  if exists(
    select 1 from public.memberships m
    join public.monthly_winners mw on mw.person_id=coalesce(m.current_holder_person_id,m.person_id)
    join public.cycles wc on wc.id=mw.cycle_id
    where m.id=any(final_membership_ids) and wc.kuri_id=v_kuri_id and wc.id<>target_cycle_id
  ) then
    raise exception 'A current holder who has already won in this Kuri cannot win again.';
  end if;

  select count(distinct coalesce(m.current_holder_person_id,m.person_id)) into v_unwon_member_count
  from public.memberships m
  where m.kuri_id=v_kuri_id and m.status='ACTIVE'
    and not exists(
      select 1 from public.monthly_winners mw join public.cycles wc on wc.id=mw.cycle_id
      where wc.kuri_id=v_kuri_id
        and mw.person_id=coalesce(m.current_holder_person_id,m.person_id)
    );

  select greatest(k.number_of_cycles-c.cycle_number+1,0) into v_remaining_cycles
  from public.kuris k join public.cycles c on c.kuri_id=k.id
  where k.id=v_kuri_id and c.id=target_cycle_id;

  if v_remaining_cycles<1 then raise exception 'Unable to determine remaining cycles for winner finalization.'; end if;
  if v_unwon_member_count<v_remaining_cycles then
    raise exception 'Insufficient remaining current holders for the remaining cycles; repeating winners is not allowed.';
  end if;

  v_max_winners:=v_unwon_member_count-(v_remaining_cycles-1);
  if array_length(final_membership_ids,1)>v_max_winners then
    raise exception 'Selected winner count exceeds the maximum feasible winner count of %.',v_max_winners;
  end if;

  insert into public.monthly_winners(cycle_id,person_id,selection_source,finalized_by,finalized_at)
  select target_cycle_id,coalesce(m.current_holder_person_id,m.person_id),'RANDOM_DRAW',
         (select id from public.users where id=auth.uid()),now()
  from public.memberships m
  where m.id=any(final_membership_ids)
  group by coalesce(m.current_holder_person_id,m.person_id);

  insert into public.monthly_winner_memberships(monthly_winner_id,membership_id)
  select mw.id,m.id from public.monthly_winners mw
  join public.memberships m on coalesce(m.current_holder_person_id,m.person_id)=mw.person_id
  where mw.cycle_id=target_cycle_id and m.id=any(final_membership_ids);

  perform public.transition_draw_status_for_admin(v_session_id,'FINALIZED');
  perform public.transition_cycle_status_for_admin(target_cycle_id,'COMPLETED');

  select count(*) into v_winner_count from public.monthly_winners where cycle_id=target_cycle_id;
  update public.financial_idempotency_keys
  set status='COMPLETED',result_bigint=v_winner_count,completed_at=now()
  where id=v_idem.id;
  return v_winner_count;
end
$function$;

create or replace function public.sync_expense_obligations_for_rule(target_rule_id uuid)
returns void language plpgsql security definer set search_path=''
as $function$
declare rule_row record;
begin
  select er.id,er.kuri_id,er.frequency,er.amount,er.active into rule_row
  from public.expense_rules er where er.id=target_rule_id;
  if rule_row.id is null or not rule_row.active then return; end if;

  if rule_row.frequency='ONE_TIME' then
    insert into public.expense_obligations(expense_rule_id,kuri_id,membership_id,cycle_id,amount)
    select rule_row.id,rule_row.kuri_id,m.id,null,rule_row.amount
    from public.memberships m
    where m.kuri_id=rule_row.kuri_id and m.status='ACTIVE'
      and not exists(
        select 1 from public.membership_exits me
        where me.membership_id=m.id and me.status in ('PENDING','APPROVED')
      )
    on conflict do nothing;
  else
    insert into public.expense_obligations(expense_rule_id,kuri_id,membership_id,cycle_id,amount)
    select rule_row.id,rule_row.kuri_id,m.id,c.id,rule_row.amount
    from public.memberships m join public.cycles c on c.kuri_id=m.kuri_id
    where m.kuri_id=rule_row.kuri_id and m.status='ACTIVE'
      and c.status not in ('COMPLETED','CANCELLED')
      and not exists(
        select 1 from public.membership_exits me
        where me.membership_id=m.id and me.status in ('PENDING','APPROVED')
      )
    on conflict do nothing;
  end if;
end
$function$;

create or replace function public.sync_expense_obligations_for_membership(target_membership_id uuid)
returns void language plpgsql security definer set search_path=''
as $function$
declare target_kuri_id uuid; rule_row record;
begin
  select m.kuri_id into target_kuri_id
  from public.memberships m
  where m.id=target_membership_id and m.status='ACTIVE'
    and not exists(
      select 1 from public.membership_exits me
      where me.membership_id=m.id and me.status in ('PENDING','APPROVED')
    );

  if target_kuri_id is null then return; end if;

  for rule_row in
    select er.id,er.frequency,er.amount from public.expense_rules er
    where er.kuri_id=target_kuri_id and er.active order by er.id
  loop
    if rule_row.frequency='ONE_TIME' then
      insert into public.expense_obligations(expense_rule_id,kuri_id,membership_id,cycle_id,amount)
      values(rule_row.id,target_kuri_id,target_membership_id,null,rule_row.amount)
      on conflict do nothing;
    else
      insert into public.expense_obligations(expense_rule_id,kuri_id,membership_id,cycle_id,amount)
      select rule_row.id,target_kuri_id,target_membership_id,c.id,rule_row.amount
      from public.cycles c
      where c.kuri_id=target_kuri_id and c.status not in ('COMPLETED','CANCELLED')
      on conflict do nothing;
    end if;
  end loop;
end
$function$;

commit;
