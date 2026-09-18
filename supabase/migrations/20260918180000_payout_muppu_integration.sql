begin;

create or replace function public.prepare_payout_for_admin(target_winner_id uuid)
returns uuid
language plpgsql security definer set search_path=public
as $$
declare
  payout_id uuid;
  winner_person_id uuid;
  winner_cycle_id uuid;
  gross_amount bigint;
  configured_muppu_amount bigint;
  deducted_muppu_amount bigint;
  payout_muppu_amount bigint;
begin
  select mw.person_id,mw.cycle_id,k.gross_prize_amount,k.muppu_amount
    into winner_person_id,winner_cycle_id,gross_amount,configured_muppu_amount
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

  if winner_person_id is null then
    raise exception 'Monthly winner not found.';
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

  payout_muppu_amount := greatest(
    coalesce(configured_muppu_amount,0),
    deducted_muppu_amount
  );

  select po.id
    into payout_id
  from public.payouts po
  where po.monthly_winner_id=target_winner_id;

  if payout_id is null then
    insert into public.payouts(
      monthly_winner_id,
      gross_amount,
      muppu_amount,
      other_deductions,
      net_amount,
      status
    )
    values(
      target_winner_id,
      gross_amount,
      payout_muppu_amount,
      0,
      greatest(gross_amount-payout_muppu_amount,0),
      'PENDING'
    )
    returning id into payout_id;
  else
    update public.payouts po
    set muppu_amount=payout_muppu_amount,
        net_amount=greatest(
          po.gross_amount-payout_muppu_amount-coalesce(po.other_deductions,0),
          0
        )
    where po.id=payout_id
      and po.status='PENDING';
  end if;

  return payout_id;
end;
$$;

revoke all on function public.prepare_payout_for_admin(uuid) from public;
grant execute on function public.prepare_payout_for_admin(uuid) to authenticated;

commit;
