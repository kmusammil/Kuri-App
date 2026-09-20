begin;

create or replace function public.create_membership_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  target_membership_number text
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  membership_id_value uuid;
  target_org_id uuid;
  cycle_row record;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  select k.organization_id into target_org_id
  from public.kuris k
  where k.id=target_kuri_id;

  if target_org_id is null then
    raise exception 'Kuri not found.';
  end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to add memberships.';
  end if;

  if not exists (
    select 1 from public.people p where p.id=target_person_id
  ) then
    raise exception 'Person not found.';
  end if;

  insert into public.memberships(kuri_id,person_id,membership_number,status)
  values(target_kuri_id,target_person_id,nullif(btrim(target_membership_number),''),'ACTIVE')
  returning id into membership_id_value;

  for cycle_row in
    select id,due_date
    from public.cycles
    where kuri_id=target_kuri_id
    order by cycle_number
  loop
    insert into public.installments(
      membership_id,cycle_id,amount_due,amount_paid,status,due_date
    )
    select
      membership_id_value,
      cycle_row.id,
      k.installment_amount,
      0,
      'UNPAID'::public.installment_status,
      cycle_row.due_date
    from public.kuris k
    where k.id=target_kuri_id
    on conflict (membership_id,cycle_id) do nothing;
  end loop;

  return membership_id_value;
end;
$$;

revoke all on function public.create_membership_for_admin(uuid,uuid,text) from public;
grant execute on function public.create_membership_for_admin(uuid,uuid,text) to authenticated;

commit;
