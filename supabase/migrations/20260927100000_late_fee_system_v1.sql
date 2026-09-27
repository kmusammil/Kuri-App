-- LATE-FEE-001: optional, versioned Kuri late-fee configuration and
-- per-installment Expense-backed late-fee obligations.
BEGIN;

-- LATE-FEE-001: optional, versioned Kuri late-fee configuration.
do $$
begin
  if not exists (
    select 1
    from pg_type t
    join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='late_fee_type'
  ) then
    create type public.late_fee_type as enum ('FIXED','PERCENTAGE');
  end if;
end $$;

create table if not exists public.kuri_late_fee_rules (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  expense_rule_id uuid not null references public.expense_rules(id) on delete restrict,
  enabled boolean not null default false,
  fee_type public.late_fee_type not null default 'FIXED',
  fixed_amount bigint,
  percentage_basis_points integer,
  grace_period_days integer not null default 0,
  effective_from date not null default current_date,
  effective_to date,
  created_by uuid references public.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kuri_late_fee_rules_grace_check
    check (grace_period_days between 0 and 3660),
  constraint kuri_late_fee_rules_effective_range_check
    check (effective_to is null or effective_to >= effective_from),
  constraint kuri_late_fee_rules_shape_check
    check (
      not enabled
      or (
        (fee_type='FIXED' and fixed_amount > 0 and percentage_basis_points is null)
        or
        (fee_type='PERCENTAGE' and fixed_amount is null and percentage_basis_points between 1 and 10000)
      )
    )
);

create unique index if not exists kuri_late_fee_rules_current_uniq
  on public.kuri_late_fee_rules(kuri_id)
  where effective_to is null;

create index if not exists kuri_late_fee_rules_lookup_idx
  on public.kuri_late_fee_rules(kuri_id,effective_from,effective_to);

alter table public.kuri_late_fee_rules enable row level security;
revoke all on table public.kuri_late_fee_rules from public, anon, authenticated;

create table if not exists public.late_fee_obligations (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  membership_id uuid not null references public.memberships(id) on delete restrict,
  installment_id uuid not null references public.installments(id) on delete restrict,
  late_fee_rule_id uuid not null references public.kuri_late_fee_rules(id) on delete restrict,
  expense_obligation_id uuid not null references public.expense_obligations(id) on delete restrict,
  fee_due_date date not null,
  created_at timestamptz not null default now(),
  constraint late_fee_obligations_installment_uniq unique (installment_id),
  constraint late_fee_obligations_expense_uniq unique (expense_obligation_id)
);

create index if not exists late_fee_obligations_membership_idx
  on public.late_fee_obligations(membership_id);

alter table public.late_fee_obligations enable row level security;
revoke all on table public.late_fee_obligations from public, anon, authenticated;

create or replace function public.ensure_kuri_late_fee_support(target_kuri_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_expense_rule_id uuid;
begin
  if target_kuri_id is null then
    raise exception 'Kuri is required.';
  end if;

  select er.id
    into v_expense_rule_id
  from public.expense_rules er
  where er.kuri_id=target_kuri_id
    and er.name='[SYSTEM] Late Fee Charges'
    and er.description='System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.'
  order by er.created_at
  limit 1;

  if v_expense_rule_id is null then
    insert into public.expense_rules(
      kuri_id,name,description,frequency,amount,active,created_by
    )
    select
      k.id,
      '[SYSTEM] Late Fee Charges',
      'System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.',
      'ONE_TIME'::public.expense_frequency,
      1,
      false,
      null
    from public.kuris k
    where k.id=target_kuri_id
    returning id into v_expense_rule_id;
  end if;

  if v_expense_rule_id is null then
    raise exception 'Kuri not found.';
  end if;

  insert into public.kuri_late_fee_rules(
    kuri_id,expense_rule_id,enabled,fee_type,fixed_amount,percentage_basis_points,
    grace_period_days,effective_from
  )
  select
    target_kuri_id,v_expense_rule_id,false,'FIXED',null,null,0,current_date
  where not exists (
    select 1
    from public.kuri_late_fee_rules r
    where r.kuri_id=target_kuri_id and r.effective_to is null
  );
end;
$$;

revoke all on function public.ensure_kuri_late_fee_support(uuid) from public, anon, authenticated;

create or replace function public.initialize_kuri_late_fee_support()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  perform public.ensure_kuri_late_fee_support(new.id);
  return new;
end;
$$;

drop trigger if exists initialize_kuri_late_fee_support on public.kuris;
create trigger initialize_kuri_late_fee_support
after insert on public.kuris
for each row execute function public.initialize_kuri_late_fee_support();

revoke all on function public.initialize_kuri_late_fee_support() from public, anon, authenticated;

do $$
declare
  r record;
begin
  for r in select id from public.kuris loop
    perform public.ensure_kuri_late_fee_support(r.id);
  end loop;
end $$;

-- Closed configuration history is immutable. The only permitted historical update
-- is the controlled closing of the current version at current_date - 1.
create or replace function public.guard_kuri_late_fee_rule_history()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if tg_op='DELETE' then
    raise exception 'Late-fee rule history cannot be deleted.';
  end if;

  if old.effective_to is not null then
    raise exception 'Closed late-fee rule history is immutable.';
  end if;

  if old.effective_from=current_date then
    if new.kuri_id is distinct from old.kuri_id
       or new.expense_rule_id is distinct from old.expense_rule_id
       or new.effective_from is distinct from old.effective_from
       or new.effective_to is distinct from old.effective_to then
      raise exception 'Current late-fee rule identity/effective dates cannot be changed.';
    end if;
    return new;
  end if;

  if new.effective_from is distinct from old.effective_from
     or new.effective_to is distinct from current_date-1
     or new.kuri_id is distinct from old.kuri_id
     or new.expense_rule_id is distinct from old.expense_rule_id
     or new.enabled is distinct from old.enabled
     or new.fee_type is distinct from old.fee_type
     or new.fixed_amount is distinct from old.fixed_amount
     or new.percentage_basis_points is distinct from old.percentage_basis_points
     or new.grace_period_days is distinct from old.grace_period_days
     or new.created_by is distinct from old.created_by
     or new.created_at is distinct from old.created_at then
    raise exception 'Historical late-fee rule may only be closed at its end date.';
  end if;

  new.updated_at:=now();
  return new;
end;
$$;

drop trigger if exists guard_kuri_late_fee_rule_history on public.kuri_late_fee_rules;
create trigger guard_kuri_late_fee_rule_history
before update or delete on public.kuri_late_fee_rules
for each row execute function public.guard_kuri_late_fee_rule_history();

revoke all on function public.guard_kuri_late_fee_rule_history() from public, anon, authenticated;

create or replace function public.set_late_fee_config_for_admin(
  target_kuri_id uuid,
  fee_enabled boolean,
  fee_type_value public.late_fee_type default 'FIXED',
  fixed_amount_value bigint default null,
  percentage_basis_points_value integer default null,
  grace_period_days_value integer default 0
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_actor uuid:=auth.uid();
  v_current public.kuri_late_fee_rules%rowtype;
  v_rule_id uuid;
  v_expense_rule_id uuid;
  v_org_id uuid;
  v_effective_from date:=current_date;
  v_new_fixed bigint;
  v_new_pct integer;
begin
  if v_actor is null then
    raise exception 'You must be signed in.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to configure late fees for this Kuri.';
  end if;

  if grace_period_days_value is null or grace_period_days_value<0 or grace_period_days_value>3660 then
    raise exception 'Grace period must be between 0 and 3660 days.';
  end if;

  perform public.ensure_kuri_late_fee_support(target_kuri_id);

  select k.organization_id
    into v_org_id
  from public.kuris k
  where k.id=target_kuri_id;

  if v_org_id is null then
    raise exception 'Kuri not found.';
  end if;

  select *
    into v_current
  from public.kuri_late_fee_rules r
  where r.kuri_id=target_kuri_id
    and r.effective_to is null
  for update;

  select er.id
    into v_expense_rule_id
  from public.expense_rules er
  where er.kuri_id=target_kuri_id
    and er.name='[SYSTEM] Late Fee Charges'
    and er.description='System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.'
  order by er.created_at
  limit 1;

  if fee_enabled then
    if fee_type_value='FIXED' then
      if fixed_amount_value is null or fixed_amount_value<=0 then
        raise exception 'Fixed late fee must be greater than zero.';
      end if;
      v_new_fixed:=fixed_amount_value;
      v_new_pct:=null;
    else
      if percentage_basis_points_value is null
         or percentage_basis_points_value<1
         or percentage_basis_points_value>10000 then
        raise exception 'Percentage late fee must be between 0.01 percent and 100 percent.';
      end if;
      v_new_fixed:=null;
      v_new_pct:=percentage_basis_points_value;
    end if;
  else
    v_new_fixed:=null;
    v_new_pct:=null;
    fee_type_value:='FIXED';
  end if;

  if v_current.id is not null and v_current.effective_from=current_date then
    update public.kuri_late_fee_rules
    set enabled=fee_enabled,
        fee_type=fee_type_value,
        fixed_amount=v_new_fixed,
        percentage_basis_points=v_new_pct,
        grace_period_days=grace_period_days_value,
        updated_at=now()
    where id=v_current.id
    returning id into v_rule_id;
  else
    if v_current.id is not null then
      update public.kuri_late_fee_rules
      set effective_to=current_date-1
      where id=v_current.id;
    end if;

    insert into public.kuri_late_fee_rules(
      kuri_id,expense_rule_id,enabled,fee_type,fixed_amount,percentage_basis_points,
      grace_period_days,effective_from,created_by
    )
    values(
      target_kuri_id,v_expense_rule_id,fee_enabled,fee_type_value,v_new_fixed,v_new_pct,
      grace_period_days_value,v_effective_from,
      (select id from public.users where id=v_actor)
    )
    returning id into v_rule_id;
  end if;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  values(
    v_org_id,v_actor,
    case when v_current.id is null then 'create' else 'update' end,
    'kuri_late_fee_rules',
    v_rule_id,
    case when v_current.id is null then null else to_jsonb(v_current) end,
    (select to_jsonb(r) from public.kuri_late_fee_rules r where r.id=v_rule_id),
    'Late-fee configuration change'
  );

  return v_rule_id;
end;
$$;

revoke all on function public.set_late_fee_config_for_admin(uuid,boolean,public.late_fee_type,bigint,integer,integer) from public, anon;
grant execute on function public.set_late_fee_config_for_admin(uuid,boolean,public.late_fee_type,bigint,integer,integer) to authenticated;

create or replace function public.get_late_fee_config_for_admin(target_kuri_id uuid)
returns table(
  late_fee_rule_id uuid,
  kuri_id uuid,
  enabled boolean,
  fee_type public.late_fee_type,
  fixed_amount bigint,
  percentage_basis_points integer,
  percentage numeric,
  grace_period_days integer,
  effective_from date,
  effective_to date
)
language sql
stable
security definer
set search_path=public
as $$
  select
    r.id,
    r.kuri_id,
    r.enabled,
    r.fee_type,
    r.fixed_amount,
    r.percentage_basis_points,
    case when r.percentage_basis_points is null then null
         else round(r.percentage_basis_points::numeric/100,2) end,
    r.grace_period_days,
    r.effective_from,
    r.effective_to
  from public.kuri_late_fee_rules r
  where r.kuri_id=target_kuri_id
    and r.effective_to is null
    and public.has_kuri_admin_role(
      r.kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );
$$;

revoke all on function public.get_late_fee_config_for_admin(uuid) from public, anon;
grant execute on function public.get_late_fee_config_for_admin(uuid) to authenticated;

create or replace function public.generate_late_fee_obligations_for_membership_internal(
  target_membership_id uuid,
  through_date date
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_created integer:=0;
begin
  if target_membership_id is null or through_date is null then
    raise exception 'Membership and through date are required.';
  end if;

  if through_date>current_date then
    raise exception 'Late-fee obligations cannot be generated for a future date.';
  end if;

  with candidates as (
    select
      i.id installment_id,
      i.membership_id,
      i.cycle_id,
      i.amount_due,
      i.due_date,
      r.id late_fee_rule_id,
      r.expense_rule_id,
      (i.due_date + r.grace_period_days) fee_due_date,
      case
        when r.fee_type='FIXED' then r.fixed_amount
        else greatest(
          1::numeric,
          round(i.amount_due::numeric * r.percentage_basis_points::numeric / 10000.0)
        )::bigint
      end fee_amount,
      coalesce(paid.paid_by_deadline,0)::bigint paid_by_deadline
    from public.installments i
    join public.memberships m on m.id=i.membership_id
    join lateral (
      select r.*
      from public.kuri_late_fee_rules r
      where r.kuri_id=m.kuri_id
        and r.enabled
        and i.due_date>=r.effective_from
        and (r.effective_to is null or i.due_date<=r.effective_to)
      order by r.effective_from desc,r.created_at desc
      limit 1
    ) r on true
    left join lateral (
      select coalesce(sum(
        public.get_effective_payment_allocation_amount(pa.id)
      ),0)::bigint paid_by_deadline
      from public.payment_allocations pa
      join public.payments p on p.id=pa.payment_id
      where pa.installment_id=i.id
        and p.status='APPROVED'
        and p.payment_date::date <= (i.due_date + r.grace_period_days)
    ) paid on true
    where i.membership_id=target_membership_id
      and i.status<>'WAIVED'
      and through_date >= (i.due_date + r.grace_period_days)
      and coalesce(paid.paid_by_deadline,0) < i.amount_due
      and not exists (
        select 1
        from public.membership_exits me
        where me.membership_id=i.membership_id
          and me.status in ('PENDING','APPROVED','SETTLED')
          and (i.due_date + r.grace_period_days) >
              coalesce(
                case
                  when me.reason='DEATH' and me.death_date_verified_at is not null
                  then me.death_date
                  else me.requested_at::date
                end,
                me.exit_date
              )
      )
      and not exists (
        select 1
        from public.late_fee_obligations lfo
        where lfo.installment_id=i.id
      )
  ), inserted as (
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,
      status,occurrence_date,settlement_reference
    )
    select
      c.expense_rule_id,
      m.kuri_id,
      c.membership_id,
      c.cycle_id,
      c.fee_amount,
      'UNPAID'::public.expense_obligation_status,
      c.fee_due_date,
      'LATE_FEE:'||c.installment_id::text
    from candidates c
    join public.memberships m on m.id=c.membership_id
    where c.fee_amount>0
    on conflict do nothing
    returning id,membership_id
  )
  insert into public.late_fee_obligations(
    kuri_id,membership_id,installment_id,late_fee_rule_id,
    expense_obligation_id,fee_due_date
  )
  select
    m.kuri_id,c.membership_id,c.installment_id,c.late_fee_rule_id,
    iob.id,c.fee_due_date
  from candidates c
  join inserted iob on iob.membership_id=c.membership_id
  join public.memberships m on m.id=c.membership_id
  where iob.id is not null
  on conflict (installment_id) do nothing;

  get diagnostics v_created=row_count;
  return v_created;
end;
$$;

revoke all on function public.generate_late_fee_obligations_for_membership_internal(uuid,date) from public, anon, authenticated;

create or replace function public.generate_late_fee_obligations_for_membership(
  target_membership_id uuid,
  through_date date default current_date
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_kuri_id uuid;
  v_count integer;
begin
  select m.kuri_id into v_kuri_id
  from public.memberships m
  where m.id=target_membership_id;

  if v_kuri_id is null then
    raise exception 'Membership not found.';
  end if;

  if not public.has_kuri_admin_role(
    v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to generate late fees for this membership.';
  end if;

  v_count:=public.generate_late_fee_obligations_for_membership_internal(
    target_membership_id,
    least(coalesce(through_date,current_date),current_date)
  );

  return v_count;
end;
$$;

revoke all on function public.generate_late_fee_obligations_for_membership(uuid,date) from public, anon;
grant execute on function public.generate_late_fee_obligations_for_membership(uuid,date) to authenticated;

create or replace function public.generate_late_fee_obligations_for_kuri(
  target_kuri_id uuid,
  through_date date default current_date
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_count integer:=0;
  r record;
begin
  if not public.has_kuri_admin_role(
    target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to generate late fees for this Kuri.';
  end if;

  for r in
    select m.id
    from public.memberships m
    where m.kuri_id=target_kuri_id
  loop
    v_count:=v_count+
      public.generate_late_fee_obligations_for_membership_internal(
        r.id,
        least(coalesce(through_date,current_date),current_date)
      );
  end loop;

  return v_count;
end;
$$;

revoke all on function public.generate_late_fee_obligations_for_kuri(uuid,date) from public, anon;
grant execute on function public.generate_late_fee_obligations_for_kuri(uuid,date) to authenticated;

create or replace function public.list_late_fee_obligations_for_admin(target_kuri_id uuid)
returns table(
  late_fee_obligation_id uuid,
  late_fee_rule_id uuid,
  expense_obligation_id uuid,
  installment_id uuid,
  membership_id uuid,
  membership_number text,
  cycle_number integer,
  installment_due_date date,
  fee_due_date date,
  amount bigint,
  status public.expense_obligation_status,
  settled_at timestamptz,
  settlement_reference text
)
language sql
stable
security definer
set search_path=public
as $$
  select
    lfo.id,
    lfo.late_fee_rule_id,
    lfo.expense_obligation_id,
    lfo.installment_id,
    lfo.membership_id,
    m.membership_number,
    c.cycle_number,
    i.due_date,
    lfo.fee_due_date,
    eo.amount,
    eo.status,
    eo.settled_at,
    eo.settlement_reference
  from public.late_fee_obligations lfo
  join public.memberships m on m.id=lfo.membership_id
  join public.installments i on i.id=lfo.installment_id
  join public.cycles c on c.id=i.cycle_id
  join public.expense_obligations eo on eo.id=lfo.expense_obligation_id
  where lfo.kuri_id=target_kuri_id
    and public.has_kuri_admin_role(
      lfo.kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by lfo.fee_due_date desc, m.membership_number;
$$;

revoke all on function public.list_late_fee_obligations_for_admin(uuid) from public, anon;
grant execute on function public.list_late_fee_obligations_for_admin(uuid) to authenticated;

create or replace function public.correct_late_fee_obligation_for_admin(
  target_expense_obligation_id uuid,
  corrected_amount bigint,
  correction_reason text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_actor uuid:=auth.uid();
  v_kuri_id uuid;
  v_old public.expense_obligations%rowtype;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;
  if corrected_amount is null or corrected_amount<=0 then
    raise exception 'Corrected late fee must be greater than zero.';
  end if;
  if correction_reason is null or char_length(btrim(correction_reason))<3 then
    raise exception 'A correction reason is required.';
  end if;

  select eo.*
    into v_old
  from public.expense_obligations eo
  join public.late_fee_obligations lfo on lfo.expense_obligation_id=eo.id
  where eo.id=target_expense_obligation_id
  for update;

  if v_old.id is null then
    raise exception 'Late-fee obligation not found.';
  end if;

  select lfo.kuri_id
    into v_kuri_id
  from public.late_fee_obligations lfo
  where lfo.expense_obligation_id=target_expense_obligation_id;

  if not public.has_kuri_admin_role(
    v_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to correct this late fee.';
  end if;

  if v_old.status<>'UNPAID' then
    raise exception 'Only an unpaid late fee can be corrected. Use the waiver/payment workflow after settlement.';
  end if;

  update public.expense_obligations
  set amount=corrected_amount,
      updated_at=now(),
      settlement_reference=concat_ws(' | ',settlement_reference,'CORRECTED_LATE_FEE')
  where id=target_expense_obligation_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,
    v_actor,
    'correct',
    'expense_obligation',
    v_old.id,
    to_jsonb(v_old),
    to_jsonb(eo),
    btrim(correction_reason)
  from public.expense_obligations eo
  join public.kuris k on k.id=v_kuri_id
  where eo.id=v_old.id;
end;
$$;

revoke all on function public.correct_late_fee_obligation_for_admin(uuid,bigint,text) from public, anon;
grant execute on function public.correct_late_fee_obligation_for_admin(uuid,bigint,text) to authenticated;

-- Exit/death expense cutoff integration: an exit record is the natural cutoff
-- trigger. Fees already matured by the cutoff are materialized into Expense;
-- fees whose maturity is after the cutoff are never created for the case.
create or replace function public.sync_late_fee_obligations_for_exit_trigger()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
declare
  v_cutoff date;
begin
  v_cutoff:=case
    when new.reason='DEATH' and new.death_date_verified_at is not null then new.death_date
    else coalesce(new.requested_at::date,new.exit_date)
  end;

  if v_cutoff is not null and v_cutoff<=current_date
     and new.status in ('PENDING','APPROVED') then
    perform public.generate_late_fee_obligations_for_membership_internal(
      new.membership_id,
      v_cutoff
    );
  end if;

  return new;
end;
$$;

drop trigger if exists sync_late_fee_obligations_for_exit on public.membership_exits;
create trigger sync_late_fee_obligations_for_exit
after insert or update of requested_at,death_date,death_date_verified_at,status
on public.membership_exits
for each row execute function public.sync_late_fee_obligations_for_exit_trigger();

revoke all on function public.sync_late_fee_obligations_for_exit_trigger() from public, anon, authenticated;

-- Payout preparation must materialize matured late fees for the winning membership
-- before the existing expense-deduction query runs.
create or replace function public.prepare_payout_for_admin(target_winner_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
DECLARE
  v_actor_user_id uuid := auth.uid();
  v_payout_id uuid;
  v_payout_status public.payout_status;
  v_winner_cycle_id uuid;
  v_target_kuri_id uuid;
  v_winner_membership_id uuid;
  v_gross_prize_amount bigint;
  v_payout_muppu_amount bigint := 0;
  v_expense_deduction_amount bigint := 0;
  v_cycle_status public.cycle_status;
BEGIN
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT
    mw.cycle_id,
    mwm.membership_id,
    k.id,
    k.gross_prize_amount,
    c.status
  INTO
    v_winner_cycle_id,
    v_winner_membership_id,
    v_target_kuri_id,
    v_gross_prize_amount,
    v_cycle_status
  FROM public.monthly_winners mw
  JOIN public.monthly_winner_memberships mwm ON mwm.monthly_winner_id=mw.id
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(
      k.id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF mw,k,c;

  IF v_target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Monthly winner not found.';
  END IF;

  IF v_winner_membership_id IS NULL THEN
    RAISE EXCEPTION 'Winner membership not found.';
  END IF;

  IF v_cycle_status<>'COMPLETED' THEN
    RAISE EXCEPTION 'Cycle must be COMPLETED before preparing a payout.';
  END IF;

  IF v_gross_prize_amount<=0 THEN
    RAISE EXCEPTION 'Gross prize amount must be greater than zero.';
  END IF;

  SELECT po.id,po.status
    INTO v_payout_id,v_payout_status
  FROM public.payouts po
  WHERE po.monthly_winner_id=target_winner_id
  FOR UPDATE;

  IF v_payout_id IS NULL THEN
    INSERT INTO public.payouts(
      monthly_winner_id,
      gross_amount,
      muppu_amount,
      expense_deductions,
      other_deductions,
      net_amount,
      status
    )
    VALUES(
      target_winner_id,
      v_gross_prize_amount,
      0,
      0,
      0,
      v_gross_prize_amount,
      'PENDING'
    )
    RETURNING id INTO v_payout_id;
  ELSIF v_payout_status<>'PENDING' THEN
    RETURN v_payout_id;
  END IF;

  PERFORM public.generate_late_fee_obligations_for_membership_internal(
    v_winner_membership_id,
    current_date
  );

  SELECT coalesce(sum(eo.amount),0)
    INTO v_expense_deduction_amount
  FROM public.expense_obligations eo
  WHERE eo.deducted_from_payout_id=v_payout_id
    AND eo.status='DEDUCTED_FROM_PRIZE';

  UPDATE public.payouts po
  SET gross_amount=v_gross_prize_amount,
      muppu_amount=v_payout_muppu_amount,
      expense_deductions=v_expense_deduction_amount,
      net_amount=greatest(
        v_gross_prize_amount
        -v_payout_muppu_amount
        -v_expense_deduction_amount
        -po.other_deductions,
        0
      )
  WHERE po.id=v_payout_id
    AND po.status='PENDING';

  RETURN v_payout_id;
END
$function$;

revoke all on function public.prepare_payout_for_admin(uuid) from public, anon;
grant execute on function public.prepare_payout_for_admin(uuid) to authenticated;

-- LATE-FEE-001 hardening:
-- preserve the installment identity through the Expense insertion so that
-- multiple late fees generated for one membership cannot cross-link.
create or replace function public.generate_late_fee_obligations_for_membership_internal(
  target_membership_id uuid,
  through_date date
)
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_created integer:=0;
begin
  if target_membership_id is null or through_date is null then
    raise exception 'Membership and through date are required.';
  end if;

  if through_date>current_date then
    raise exception 'Late-fee obligations cannot be generated for a future date.';
  end if;

  with candidates as (
    select
      i.id installment_id,
      i.membership_id,
      i.cycle_id,
      i.amount_due,
      i.due_date,
      r.id late_fee_rule_id,
      r.expense_rule_id,
      (i.due_date + r.grace_period_days) fee_due_date,
      case
        when r.fee_type='FIXED' then r.fixed_amount
        else greatest(
          1::numeric,
          round(i.amount_due::numeric * r.percentage_basis_points::numeric / 10000.0)
        )::bigint
      end fee_amount,
      coalesce(paid.paid_by_deadline,0)::bigint paid_by_deadline
    from public.installments i
    join public.memberships m on m.id=i.membership_id
    join lateral (
      select r.*
      from public.kuri_late_fee_rules r
      where r.kuri_id=m.kuri_id
        and r.enabled
        and i.due_date>=r.effective_from
        and (r.effective_to is null or i.due_date<=r.effective_to)
      order by r.effective_from desc,r.created_at desc
      limit 1
    ) r on true
    left join lateral (
      select coalesce(sum(
        public.get_effective_payment_allocation_amount(pa.id)
      ),0)::bigint paid_by_deadline
      from public.payment_allocations pa
      join public.payments p on p.id=pa.payment_id
      where pa.installment_id=i.id
        and p.status='APPROVED'
        and p.payment_date::date <= (i.due_date + r.grace_period_days)
    ) paid on true
    where i.membership_id=target_membership_id
      and i.status<>'WAIVED'
      and through_date >= (i.due_date + r.grace_period_days)
      and coalesce(paid.paid_by_deadline,0) < i.amount_due
      and not exists (
        select 1
        from public.membership_exits me
        where me.membership_id=i.membership_id
          and me.status in ('PENDING','APPROVED','SETTLED')
          and (i.due_date + r.grace_period_days) >
              coalesce(
                case
                  when me.reason='DEATH' and me.death_date_verified_at is not null
                  then me.death_date
                  else me.requested_at::date
                end,
                me.exit_date
              )
      )
      and not exists (
        select 1
        from public.late_fee_obligations lfo
        where lfo.installment_id=i.id
      )
  ), inserted as (
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,
      status,occurrence_date,settlement_reference
    )
    select
      c.expense_rule_id,
      m.kuri_id,
      c.membership_id,
      c.cycle_id,
      c.fee_amount,
      'UNPAID'::public.expense_obligation_status,
      c.fee_due_date,
      'LATE_FEE:'||c.installment_id::text
    from candidates c
    join public.memberships m on m.id=c.membership_id
    where c.fee_amount>0
    on conflict do nothing
    returning id,membership_id,settlement_reference
  )
  insert into public.late_fee_obligations(
    kuri_id,membership_id,installment_id,late_fee_rule_id,
    expense_obligation_id,fee_due_date
  )
  select
    m.kuri_id,
    c.membership_id,
    c.installment_id,
    c.late_fee_rule_id,
    iob.id,
    c.fee_due_date
  from candidates c
  join inserted iob
    on iob.membership_id=c.membership_id
   and iob.settlement_reference='LATE_FEE:'||c.installment_id::text
  join public.memberships m on m.id=c.membership_id
  on conflict (installment_id) do nothing;

  get diagnostics v_created=row_count;
  return v_created;
end;
$function$;

revoke all on function public.generate_late_fee_obligations_for_membership_internal(uuid,date) from public, anon, authenticated;

-- LATE-FEE-001 hardening:
-- Late fees are per-installment financial obligations. Their system Expense
-- anchor therefore uses the existing RECURRING/PER_CYCLE Expense semantics,
-- not ONE_TIME semantics, so each installment can carry cycle/date identity.
update public.expense_rules
set frequency='RECURRING'::public.expense_frequency,
    recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern,
    recurrence_interval=null,
    recurrence_start_date=null,
    recurrence_end_date=null,
    active=false,
    updated_at=now()
where name='[SYSTEM] Late Fee Charges'
  and description='System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.';

create or replace function public.ensure_kuri_late_fee_support(target_kuri_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_expense_rule_id uuid;
begin
  if target_kuri_id is null then
    raise exception 'Kuri is required.';
  end if;

  select er.id
    into v_expense_rule_id
  from public.expense_rules er
  where er.kuri_id=target_kuri_id
    and er.name='[SYSTEM] Late Fee Charges'
    and er.description='System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.'
  order by er.created_at
  limit 1;

  if v_expense_rule_id is null then
    insert into public.expense_rules(
      kuri_id,name,description,frequency,amount,active,
      recurrence_pattern,recurrence_interval,recurrence_start_date,recurrence_end_date,created_by
    )
    select
      k.id,
      '[SYSTEM] Late Fee Charges',
      'System expense rule used as the accounting anchor for calculated Kuri late-fee obligations.',
      'RECURRING'::public.expense_frequency,
      1,
      false,
      'PER_CYCLE'::public.expense_recurrence_pattern,
      null,
      null,
      null,
      null
    from public.kuris k
    where k.id=target_kuri_id
    returning id into v_expense_rule_id;
  else
    update public.expense_rules
    set frequency='RECURRING'::public.expense_frequency,
        recurrence_pattern='PER_CYCLE'::public.expense_recurrence_pattern,
        recurrence_interval=null,
        recurrence_start_date=null,
        recurrence_end_date=null,
        active=false,
        updated_at=now()
    where id=v_expense_rule_id;
  end if;

  if v_expense_rule_id is null then
    raise exception 'Kuri not found.';
  end if;

  insert into public.kuri_late_fee_rules(
    kuri_id,expense_rule_id,enabled,fee_type,fixed_amount,percentage_basis_points,
    grace_period_days,effective_from
  )
  select
    target_kuri_id,v_expense_rule_id,false,'FIXED',null,null,0,current_date
  where not exists (
    select 1
    from public.kuri_late_fee_rules r
    where r.kuri_id=target_kuri_id and r.effective_to is null
  );
end;
$$;

revoke all on function public.ensure_kuri_late_fee_support(uuid) from public, anon, authenticated;

create or replace function public.generate_late_fee_obligations_for_membership_internal(
  target_membership_id uuid,
  through_date date
)
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_created integer:=0;
begin
  if target_membership_id is null or through_date is null then
    raise exception 'Membership and through date are required.';
  end if;

  if through_date>current_date then
    raise exception 'Late-fee obligations cannot be generated for a future date.';
  end if;

  with candidates as (
    select
      i.id installment_id,
      i.membership_id,
      i.cycle_id,
      i.amount_due,
      i.due_date,
      r.id late_fee_rule_id,
      r.expense_rule_id,
      (i.due_date + r.grace_period_days) fee_due_date,
      case
        when r.fee_type='FIXED' then r.fixed_amount
        else greatest(
          1::numeric,
          round(i.amount_due::numeric * r.percentage_basis_points::numeric / 10000.0)
        )::bigint
      end fee_amount,
      coalesce(paid.paid_by_deadline,0)::bigint paid_by_deadline
    from public.installments i
    join public.memberships m on m.id=i.membership_id
    join lateral (
      select r.*
      from public.kuri_late_fee_rules r
      where r.kuri_id=m.kuri_id
        and r.enabled
        and i.due_date>=r.effective_from
        and (r.effective_to is null or i.due_date<=r.effective_to)
      order by r.effective_from desc,r.created_at desc
      limit 1
    ) r on true
    left join lateral (
      select coalesce(sum(
        public.get_effective_payment_allocation_amount(pa.id)
      ),0)::bigint paid_by_deadline
      from public.payment_allocations pa
      join public.payments p on p.id=pa.payment_id
      where pa.installment_id=i.id
        and p.status='APPROVED'
        and p.payment_date::date <= (i.due_date + r.grace_period_days)
    ) paid on true
    where i.membership_id=target_membership_id
      and i.status<>'WAIVED'
      and through_date >= (i.due_date + r.grace_period_days)
      and coalesce(paid.paid_by_deadline,0) < i.amount_due
      and not exists (
        select 1
        from public.membership_exits me
        where me.membership_id=i.membership_id
          and me.status in ('PENDING','APPROVED','SETTLED')
          and (i.due_date + r.grace_period_days) >
              coalesce(
                case
                  when me.reason='DEATH' and me.death_date_verified_at is not null
                  then me.death_date
                  else me.requested_at::date
                end,
                me.exit_date
              )
      )
      and not exists (
        select 1
        from public.late_fee_obligations lfo
        where lfo.installment_id=i.id
      )
  ), inserted as (
    insert into public.expense_obligations(
      expense_rule_id,kuri_id,membership_id,cycle_id,amount,
      status,occurrence_date,settlement_reference
    )
    select
      c.expense_rule_id,
      m.kuri_id,
      c.membership_id,
      c.cycle_id,
      c.fee_amount,
      'UNPAID'::public.expense_obligation_status,
      c.fee_due_date,
      'LATE_FEE:'||c.installment_id::text
    from candidates c
    join public.memberships m on m.id=c.membership_id
    where c.fee_amount>0
    on conflict do nothing
    returning id,membership_id,settlement_reference
  )
  insert into public.late_fee_obligations(
    kuri_id,membership_id,installment_id,late_fee_rule_id,
    expense_obligation_id,fee_due_date
  )
  select
    m.kuri_id,
    c.membership_id,
    c.installment_id,
    c.late_fee_rule_id,
    iob.id,
    c.fee_due_date
  from candidates c
  join inserted iob
    on iob.membership_id=c.membership_id
   and iob.settlement_reference='LATE_FEE:'||c.installment_id::text
  join public.memberships m on m.id=c.membership_id
  on conflict (installment_id) do nothing;

  get diagnostics v_created=row_count;
  return v_created;
end;
$function$;

revoke all on function public.generate_late_fee_obligations_for_membership_internal(uuid,date) from public, anon, authenticated;


-- Integrate late-fee materialization into the branch's canonical Expense payout path.
CREATE OR REPLACE FUNCTION public.prepare_payout_for_admin(target_winner_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_user_id uuid := auth.uid();
  v_payout_id uuid;
  v_payout_status public.payout_status;
  v_winner_cycle_id uuid;
  v_target_kuri_id uuid;
  v_winner_membership_id uuid;
  v_gross_prize_amount bigint;
  v_payout_muppu_amount bigint := 0;
  v_expense_deduction_amount bigint := 0;
  v_cycle_status public.cycle_status;
BEGIN
  IF v_actor_user_id IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT
    mw.cycle_id,
    mwm.membership_id,
    k.id,
    k.gross_prize_amount,
    c.status
  INTO
    v_winner_cycle_id,
    v_winner_membership_id,
    v_target_kuri_id,
    v_gross_prize_amount,
    v_cycle_status
  FROM public.monthly_winners mw
  JOIN public.monthly_winner_memberships mwm ON mwm.monthly_winner_id=mw.id
  JOIN public.cycles c ON c.id=mw.cycle_id
  JOIN public.kuris k ON k.id=c.kuri_id
  WHERE mw.id=target_winner_id
    AND public.has_kuri_admin_role(
      k.id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE OF mw,k,c;

  IF v_target_kuri_id IS NULL THEN
    RAISE EXCEPTION 'Monthly winner not found.';
  END IF;

  IF v_winner_membership_id IS NULL THEN
    RAISE EXCEPTION 'Winner membership not found.';
  END IF;

  IF v_cycle_status<>'COMPLETED' THEN
    RAISE EXCEPTION 'Cycle must be COMPLETED before preparing a payout.';
  END IF;

  IF v_gross_prize_amount<=0 THEN
    RAISE EXCEPTION 'Gross prize amount must be greater than zero.';
  END IF;

  SELECT po.id,po.status
    INTO v_payout_id,v_payout_status
  FROM public.payouts po
  WHERE po.monthly_winner_id=target_winner_id
  FOR UPDATE;

  IF v_payout_id IS NULL THEN
    INSERT INTO public.payouts(
      monthly_winner_id,gross_amount,muppu_amount,expense_deductions,
      other_deductions,net_amount,status
    )
    VALUES(
      target_winner_id,v_gross_prize_amount,0,0,0,v_gross_prize_amount,'PENDING'
    )
    RETURNING id INTO v_payout_id;
  ELSIF v_payout_status<>'PENDING' THEN
    RETURN v_payout_id;
  END IF;

  PERFORM public.generate_late_fee_obligations_for_membership_internal(
    v_winner_membership_id,current_date
  );

  SELECT coalesce(sum(eo.amount),0)
    INTO v_expense_deduction_amount
  FROM public.expense_obligations eo
  WHERE eo.deducted_from_payout_id=v_payout_id
    AND eo.status='DEDUCTED_FROM_PRIZE';

  UPDATE public.payouts po
  SET gross_amount=v_gross_prize_amount,
      muppu_amount=v_payout_muppu_amount,
      expense_deductions=v_expense_deduction_amount,
      net_amount=greatest(
        v_gross_prize_amount-v_payout_muppu_amount
        -v_expense_deduction_amount-coalesce(po.other_deductions,0),0
      )
  WHERE po.id=v_payout_id
    AND po.status='PENDING';

  RETURN v_payout_id;
END
$function$;

REVOKE ALL ON FUNCTION public.prepare_payout_for_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prepare_payout_for_admin(uuid) TO authenticated;


COMMIT;
