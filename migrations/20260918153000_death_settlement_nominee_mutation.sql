begin;

alter table public.membership_exits
  add column if not exists settled_to_nominee_id uuid references public.nominees(id) on delete set null;

alter table public.membership_exits
  add column if not exists settlement_notes text;

create or replace function public.record_death_settlement_for_admin(
  target_exit_id uuid,
  target_nominee_id uuid default null,
  settlement_notes text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  target_org_id uuid;
  target_person_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select k.organization_id, m.person_id
    into target_org_id, target_person_id
  from public.membership_exits me
  join public.memberships m on m.id=me.membership_id
  join public.kuris k on k.id=m.kuri_id
  where me.id=target_exit_id and me.reason='DEATH';

  if target_org_id is null then raise exception 'Death exit record not found.'; end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then raise exception 'You do not have permission to settle this death case.'; end if;

  if not exists (
    select 1 from public.membership_exits
    where id=target_exit_id and status='APPROVED'
  ) then raise exception 'Death exit must be approved before settlement.'; end if;

  if target_nominee_id is not null and not exists (
    select 1 from public.nominees n
    where n.id=target_nominee_id and n.person_id=target_person_id
  ) then raise exception 'Selected nominee does not belong to this person.'; end if;

  update public.membership_exits
  set status='SETTLED',
      settled_at=now(),
      settled_to_nominee_id=target_nominee_id,
      settlement_notes=nullif(btrim(settlement_notes),'')
  where id=target_exit_id and status='APPROVED';

  if not found then raise exception 'Death exit must be approved before settlement.'; end if;
end;
$$;

revoke all on function public.record_death_settlement_for_admin(uuid,uuid,text) from public;
grant execute on function public.record_death_settlement_for_admin(uuid,uuid,text) to authenticated;

drop function if exists public.get_death_settlement_context_for_admin(uuid);

create function public.get_death_settlement_context_for_admin(target_membership_id uuid)
returns table (
  membership_id uuid,
  membership_number text,
  person_id uuid,
  registered_name text,
  display_name text,
  nominee_id uuid,
  nominee_name text,
  nominee_relationship text,
  nominee_phone text,
  nominee_address text,
  nominee_notes text,
  refund_policy public.refund_policy,
  amount_contributed bigint,
  refund_amount bigint,
  exit_status public.settlement_status,
  exit_date date,
  settled_to_nominee_id uuid,
  settlement_notes text
)
language sql
security definer
set search_path=public
stable
as $$
select
  m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
  n.id,n.name,n.relationship,n.phone,n.address,n.notes,
  me.refund_policy,me.amount_contributed,me.refund_amount,me.status,me.exit_date,
  me.settled_to_nominee_id,me.settlement_notes
from public.memberships m
join public.people p on p.id=m.person_id
join public.kuris k on k.id=m.kuri_id
join public.membership_exits me on me.membership_id=m.id
left join public.nominees n on n.person_id=m.person_id
  and (me.settled_to_nominee_id is null or n.id=me.settled_to_nominee_id)
where m.id=target_membership_id
  and me.reason='DEATH'
  and me.status<>'CANCELLED'
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id=k.organization_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
order by n.name,n.id;
$$;

revoke all on function public.get_death_settlement_context_for_admin(uuid) from public;
grant execute on function public.get_death_settlement_context_for_admin(uuid) to authenticated;

commit;
