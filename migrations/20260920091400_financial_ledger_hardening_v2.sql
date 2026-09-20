begin;

-- Follow-up correction for the financial hardening migration.
-- Keep the payout preparation function's SELECT/INTO arity aligned.

create or replace function public.prepare_payout_for_admin(target_winner_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  payout_id uuid;
  winner_person_id uuid;
  winner_cycle_id uuid;
  gross_amount bigint;
  configured_muppu_amount bigint;
  deducted_muppu_amount bigint;
  payout_muppu_amount bigint;
  cycle_status_value public.cycle_status;
begin
  select mw.person_id,mw.cycle_id,k.gross_prize_amount,k.muppu_amount,c.status
    into winner_person_id,winner_cycle_id,gross_amount,configured_muppu_amount,cycle_status_value
  from public.monthly_winners mw
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where mw.id=target_winner_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );

  if winner_person_id is null then raise exception 'Monthly winner not found.'; end if;
  if cycle_status_value<>'COMPLETED' then
    raise exception 'Cycle must be COMPLETED before preparing a payout.';
  end if;
  if gross_amount<=0 then
    raise exception 'Gross prize amount must be greater than zero.';
  end if;

  select coalesce(sum(mr.amount),0)
    into deducted_muppu_amount
  from public.muppu_records mr
  where mr.person_id=winner_person_id
    and mr.cycle_id=winner_cycle_id
    and mr.status='DEDUCTED';

  payout_muppu_amount:=greatest(
    coalesce(configured_muppu_amount,0),
    deducted_muppu_amount
  );

  insert into public.payouts(
    monthly_winner_id,gross_amount,muppu_amount,other_deductions,net_amount,status
  )
  values(
    target_winner_id,gross_amount,payout_muppu_amount,0,
    greatest(gross_amount-payout_muppu_amount,0),'PENDING'
  )
  on conflict(monthly_winner_id)
  do update set
    gross_amount=excluded.gross_amount,
    muppu_amount=excluded.muppu_amount,
    net_amount=greatest(
      excluded.gross_amount-excluded.muppu_amount-public.payouts.other_deductions,0
    )
  where public.payouts.status='PENDING'
  returning id into payout_id;

  if payout_id is null then
    select po.id into payout_id
    from public.payouts po
    where po.monthly_winner_id=target_winner_id;
  end if;

  return payout_id;
end;
$$;

commit;
