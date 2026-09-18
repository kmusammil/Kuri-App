begin;

create table if not exists public.membership_exit_refund_transactions (
  id uuid primary key default gen_random_uuid(),
  membership_exit_id uuid not null references public.membership_exits(id) on delete restrict,
  amount bigint not null check (amount > 0),
  payment_method public.payment_method not null,
  payment_reference text,
  paid_at timestamptz not null default now(),
  processed_by uuid references public.users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  unique (membership_exit_id)
);

alter table public.membership_exit_refund_transactions enable row level security;

create or replace function public.get_membership_exit_reconciliation_for_admin(target_exit_id uuid)
returns table (
  exit_id uuid,
  membership_id uuid,
  kuri_id uuid,
  kuri_name text,
  membership_number text,
  registered_name text,
  display_name text,
  reason public.settlement_reason,
  refund_policy public.refund_policy,
  amount_contributed bigint,
  refund_amount bigint,
  exit_status public.settlement_status,
  paid_refund_amount bigint,
  refund_balance bigint,
  refund_payment_id uuid,
  refund_payment_method public.payment_method,
  refund_payment_reference text,
  refund_paid_at timestamptz
)
language sql security definer
set search_path=public
stable
as $$
  select
    me.id,
    m.id,
    k.id,
    k.name,
    m.membership_number,
    p.registered_name,
    p.display_name,
    me.reason,
    me.refund_policy,
    me.amount_contributed,
    me.refund_amount,
    me.status,
    coalesce(rt.amount,0),
    greatest(me.refund_amount-coalesce(rt.amount,0),0),
    rt.id,
    rt.payment_method,
    rt.payment_reference,
    rt.paid_at
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  join public.people p on p.id=m.person_id
  left join public.membership_exit_refund_transactions rt on rt.membership_exit_id=me.id
  where me.id=target_exit_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$$;

create or replace function public.record_membership_exit_refund_for_admin(
  target_exit_id uuid,
  refund_amount bigint,
  refund_payment_method public.payment_method,
  refund_reference text default null,
  refund_paid_at timestamptz default null,
  refund_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  target_org_id uuid;
  expected_refund bigint;
  existing_paid bigint := 0;
  transaction_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if refund_amount <= 0 then raise exception 'Refund amount must be greater than zero.'; end if;

  select k.organization_id, me.refund_amount
    into target_org_id, expected_refund
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id;

  if target_org_id is null then raise exception 'Exit record not found.'; end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to record this refund.';
  end if;

  if not exists (
    select 1 from public.membership_exits me
    where me.id=target_exit_id
      and me.status='APPROVED'
      and me.refund_policy='IMMEDIATE'
  ) then
    raise exception 'Only approved immediate refunds can be paid here.';
  end if;

  select rt.amount into existing_paid
  from public.membership_exit_refund_transactions rt
  where rt.membership_exit_id=target_exit_id
  for update;

  if coalesce(existing_paid,0) > 0 then
    raise exception 'A refund transaction already exists for this exit.';
  end if;

  if refund_amount > expected_refund then
    raise exception 'Refund exceeds the approved refund amount.';
  end if;

  insert into public.membership_exit_refund_transactions(
    membership_exit_id,amount,payment_method,payment_reference,paid_at,processed_by,notes
  )
  values(
    target_exit_id,
    refund_amount,
    refund_payment_method,
    nullif(btrim(refund_reference),''),
    coalesce(refund_paid_at,now()),
    (select id from public.users where id=auth.uid()),
    nullif(btrim(refund_notes),'')
  )
  returning id into transaction_id;

  if refund_amount = expected_refund then
    update public.membership_exits
    set status='SETTLED',
        settled_at=coalesce(refund_paid_at,now())
    where id=target_exit_id and status='APPROVED';
  end if;

  return transaction_id;
end;
$$;

revoke all on function public.get_membership_exit_reconciliation_for_admin(uuid) from public;
revoke all on function public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text) from public;
grant execute on function public.get_membership_exit_reconciliation_for_admin(uuid) to authenticated;
grant execute on function public.record_membership_exit_refund_for_admin(uuid,bigint,public.payment_method,text,timestamptz,text) to authenticated;

commit;
