begin;

-- Replace the incompatible cycle-listing function with the shape used by the UI.
-- The existing remote function has a different OUT-parameter signature, so it
-- must be dropped before recreating it.
drop function if exists public.list_cycles_for_admin(uuid);

create function public.list_cycles_for_admin(target_kuri_id uuid)
returns table (
  id uuid,
  cycle_number integer,
  period_start date,
  period_end date,
  due_date date,
  draw_date date,
  status public.cycle_status,
  installment_count bigint,
  paid_installment_count bigint
)
language sql
security definer
set search_path = public
stable
as $$
  select
    c.id,
    c.cycle_number,
    c.period_start,
    c.period_end,
    c.due_date,
    c.draw_date,
    c.status,
    count(i.id) as installment_count,
    count(i.id) filter (where i.status in ('PAID','PAID_LATE')) as paid_installment_count
  from public.cycles c
  join public.kuris k on k.id = c.kuri_id
  left join public.installments i on i.cycle_id = c.id
  where c.kuri_id = target_kuri_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id = k.organization_id
        and ou.user_id = auth.uid()
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  group by
    c.id,
    c.cycle_number,
    c.period_start,
    c.period_end,
    c.due_date,
    c.draw_date,
    c.status
  order by c.cycle_number;
$$;

revoke all on function public.list_cycles_for_admin(uuid) from public;
grant execute on function public.list_cycles_for_admin(uuid) to authenticated;

commit;
