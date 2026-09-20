begin;

-- Admin-only RPCs for cycle details and installment records.
create or replace function public.get_cycle_for_admin(target_cycle_id uuid)
returns table (
  id uuid,
  kuri_id uuid,
  cycle_number integer,
  period_start date,
  period_end date,
  due_date date,
  draw_date date,
  status public.cycle_status
)
language sql
security definer
set search_path = public
stable
as $$
  select
    c.id,
    c.kuri_id,
    c.cycle_number,
    c.period_start,
    c.period_end,
    c.due_date,
    c.draw_date,
    c.status
  from public.cycles c
  join public.kuris k on k.id = c.kuri_id
  where c.id = target_cycle_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id = k.organization_id
        and ou.user_id = auth.uid()
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$$;

create or replace function public.list_installments_for_cycle_admin(target_cycle_id uuid)
returns table (
  id uuid,
  membership_id uuid,
  membership_number text,
  registered_name text,
  display_name text,
  amount_due bigint,
  amount_paid bigint,
  status public.installment_status,
  due_date date
)
language sql
security definer
set search_path = public
stable
as $$
  select
    i.id,
    i.membership_id,
    m.membership_number,
    p.registered_name,
    p.display_name,
    i.amount_due,
    i.amount_paid,
    i.status,
    i.due_date
  from public.installments i
  join public.memberships m on m.id = i.membership_id
  join public.people p on p.id = m.person_id
  join public.cycles c on c.id = i.cycle_id
  join public.kuris k on k.id = c.kuri_id
  where i.cycle_id = target_cycle_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id = k.organization_id
        and ou.user_id = auth.uid()
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  order by m.membership_number;
$$;

revoke all on function public.get_cycle_for_admin(uuid) from public;
revoke all on function public.list_installments_for_cycle_admin(uuid) from public;
grant execute on function public.get_cycle_for_admin(uuid) to authenticated;
grant execute on function public.list_installments_for_cycle_admin(uuid) to authenticated;

commit;
