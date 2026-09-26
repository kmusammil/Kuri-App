create or replace function public.sync_expense_obligations_for_rule(target_rule_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  target_kuri_id uuid;
  through_date date;
begin
  select er.kuri_id into target_kuri_id
  from public.expense_rules er
  where er.id=target_rule_id and er.active;

  if target_kuri_id is null then return; end if;

  select coalesce(max(c.due_date),current_date)
  into through_date
  from public.cycles c
  where c.kuri_id=target_kuri_id;

  perform public.generate_expense_obligations_for_rule(target_rule_id,through_date);
end;
$function$;

create or replace function public.sync_expense_obligations_for_kuri(target_kuri_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  rule_row record;
begin
  for rule_row in
    select er.id
    from public.expense_rules er
    where er.kuri_id=target_kuri_id and er.active
    order by er.id
  loop
    perform public.sync_expense_obligations_for_rule(rule_row.id);
  end loop;
end;
$function$;
