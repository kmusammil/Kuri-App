drop function if exists public.list_expense_rules_for_admin(uuid);

create function public.list_expense_rules_for_admin(
  target_kuri_id uuid default null
)
returns table(
  expense_rule_id uuid,
  kuri_id uuid,
  kuri_name text,
  name text,
  description text,
  frequency public.expense_frequency,
  amount bigint,
  active boolean,
  recurrence_pattern public.expense_recurrence_pattern,
  recurrence_interval integer,
  recurrence_start_date date,
  recurrence_end_date date,
  created_at timestamptz
)
language sql
stable
security definer
set search_path=public
as $$
  select
    er.id,
    er.kuri_id,
    k.name,
    er.name,
    er.description,
    er.frequency,
    er.amount,
    er.active,
    er.recurrence_pattern,
    er.recurrence_interval,
    er.recurrence_start_date,
    er.recurrence_end_date,
    er.created_at
  from public.expense_rules er
  join public.kuris k on k.id=er.kuri_id
  where (target_kuri_id is null or er.kuri_id=target_kuri_id)
    and public.has_kuri_admin_role(
      er.kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by k.created_at desc, er.created_at desc;
$$;

revoke all on function public.list_expense_rules_for_admin(uuid) from public, anon;
grant execute on function public.list_expense_rules_for_admin(uuid) to authenticated;
