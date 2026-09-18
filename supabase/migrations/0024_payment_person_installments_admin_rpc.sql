begin;

create or replace function public.list_installments_for_person_payment_admin(target_person_id uuid)
returns table (id uuid,kuri_id uuid,kuri_name text,membership_id uuid,membership_number text,cycle_id uuid,cycle_number integer,amount_due bigint,amount_paid bigint,balance bigint,status public.installment_status,due_date date)
language sql security definer set search_path=public stable
as $$
  select i.id,k.id,k.name,m.id,m.membership_number,c.id,c.cycle_number,i.amount_due,i.amount_paid,greatest(i.amount_due-i.amount_paid,0),i.status,i.due_date
  from public.installments i join public.memberships m on m.id=i.membership_id join public.cycles c on c.id=i.cycle_id join public.kuris k on k.id=c.kuri_id
  where m.person_id=target_person_id and greatest(i.amount_due-i.amount_paid,0)>0
    and exists (select 1 from public.organization_users ou where ou.organization_id=k.organization_id and ou.user_id=auth.uid() and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[]))
  order by k.name,c.cycle_number,m.membership_number;
$$;

revoke all on function public.list_installments_for_person_payment_admin(uuid) from public;
grant execute on function public.list_installments_for_person_payment_admin(uuid) to authenticated;

commit;