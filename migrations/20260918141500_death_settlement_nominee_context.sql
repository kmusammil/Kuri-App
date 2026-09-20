begin;

drop function if exists public.get_death_settlement_context_for_admin(uuid);

create or replace function public.get_membership_nominees_for_admin(target_membership_id uuid)
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
  nominee_notes text
)
language sql security definer set search_path=public stable
as $$
select m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
       n.id,n.name,n.relationship,n.phone,n.address,n.notes
from public.memberships m
join public.people p on p.id=m.person_id
join public.kuris k on k.id=m.kuri_id
left join public.nominees n on n.person_id=m.person_id
where m.id=target_membership_id
  and exists(
    select 1 from public.organization_users ou
    where ou.organization_id=k.organization_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
order by n.name,n.id;
$$;

create or replace function public.get_death_settlement_context_for_admin(target_membership_id uuid)
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
  exit_date date
)
language sql security definer set search_path=public stable
as $$
select m.id,m.membership_number,m.person_id,p.registered_name,p.display_name,
       n.id,n.name,n.relationship,n.phone,n.address,n.notes,
       me.refund_policy,me.amount_contributed,me.refund_amount,me.status,me.exit_date
from public.memberships m
join public.people p on p.id=m.person_id
join public.kuris k on k.id=m.kuri_id
join public.membership_exits me on me.membership_id=m.id
left join public.nominees n on n.person_id=m.person_id
where m.id=target_membership_id
  and me.reason='DEATH'
  and me.status<>'CANCELLED'
  and exists(
    select 1 from public.organization_users ou
    where ou.organization_id=k.organization_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  )
order by n.name,n.id;
$$;

revoke all on function public.get_membership_nominees_for_admin(uuid) from public;
revoke all on function public.get_death_settlement_context_for_admin(uuid) from public;
grant execute on function public.get_membership_nominees_for_admin(uuid) to authenticated;
grant execute on function public.get_death_settlement_context_for_admin(uuid) to authenticated;

commit;