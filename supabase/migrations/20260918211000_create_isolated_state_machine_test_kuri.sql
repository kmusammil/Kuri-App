begin;

create or replace function public.create_isolated_state_machine_test_kuri()
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  org_id uuid;
  new_kuri_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select ou.organization_id into org_id
  from public.organization_users ou
  where ou.user_id=auth.uid()
    and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  order by ou.created_at asc
  limit 1;

  if org_id is null then raise exception 'You do not have permission to create a test Kuri.'; end if;

  insert into public.kuris(
    organization_id,name,description,start_date,number_of_cycles,membership_limit,
    installment_amount,frequency,due_day,draw_day,gross_prize_amount,muppu_amount,
    winner_rule,exit_refund_rule,status
  )
  values(
    org_id,'STATE-MACHINE-TEST','Isolated backend lifecycle test Kuri',
    current_date,4,1,100,'MONTHLY',10,15,1000,0,
    'ALL_PERSON_MEMBERSHIPS','AT_MATURITY','DRAFT'
  )
  returning id into new_kuri_id;

  return new_kuri_id;
end;
$$;

revoke all on function public.create_isolated_state_machine_test_kuri() from public;
grant execute on function public.create_isolated_state_machine_test_kuri() to authenticated;

commit;
