begin;

insert into public.installments (membership_id, cycle_id, amount_due, amount_paid, status, due_date)
select m.id, c.id, k.installment_amount, 0, 'UNPAID'::public.installment_status, c.due_date
from public.memberships m
join public.kuris k on k.id=m.kuri_id
join public.cycles c on c.kuri_id=k.id
where m.id='b0c7a172-7a0f-43e9-aad4-71cbef8462e4'
  and not exists (
    select 1 from public.installments i
    where i.membership_id=m.id and i.cycle_id=c.id
  );

commit;
