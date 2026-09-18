begin;

create or replace function public.finalize_draw_for_admin(
  target_cycle_id uuid,
  final_membership_ids uuid[]
)
returns integer
language plpgsql security definer set search_path=public
as $$
declare
  session_id uuid;
  target_kuri_id uuid;
  winner_count integer;
  selected_count integer;
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;

  select d.id,c.kuri_id into session_id,target_kuri_id
  from public.draw_sessions d
  join public.cycles c on c.id=d.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where d.cycle_id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id
        and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );

  if session_id is null then raise exception 'Prepare and run the draw before finalizing winners.'; end if;
  if coalesce(array_length(final_membership_ids,1),0)<1 then raise exception 'Select at least one winner.'; end if;

  select count(*) into selected_count
  from public.draw_selections s
  where s.draw_session_id=session_id and s.membership_id=any(final_membership_ids);

  if selected_count<>array_length(final_membership_ids,1) then
    raise exception 'Final winners must come from the current draw selections.';
  end if;

  if exists (
    select 1 from public.memberships m
    where m.id=any(final_membership_ids) and m.kuri_id<>target_kuri_id
  ) then
    raise exception 'A selected membership does not belong to this Kuri.';
  end if;

  delete from public.monthly_winner_memberships
  where monthly_winner_id in (
    select id from public.monthly_winners where cycle_id=target_cycle_id
  );
  delete from public.monthly_winners where cycle_id=target_cycle_id;

  insert into public.monthly_winners(
    cycle_id,person_id,selection_source,finalized_by,finalized_at
  )
  select
    target_cycle_id,
    m.person_id,
    'RANDOM_DRAW',
    (select id from public.users where id=auth.uid()),
    now()
  from public.memberships m
  where m.id=any(final_membership_ids);

  insert into public.monthly_winner_memberships(monthly_winner_id,membership_id)
  select mw.id,m.id
  from public.monthly_winners mw
  join public.memberships m on m.person_id=mw.person_id
  where mw.cycle_id=target_cycle_id and m.id=any(final_membership_ids);

  update public.draw_sessions set status='FINALIZED',completed_at=coalesce(completed_at,now())
  where id=session_id;

  select count(*) into winner_count from public.monthly_winners where cycle_id=target_cycle_id;
  return winner_count;
end;
$$;

create or replace function public.get_monthly_winners_for_admin(target_cycle_id uuid)
returns table (
  winner_id uuid,
  person_id uuid,
  registered_name text,
  display_name text,
  selection_source text,
  finalized_by uuid,
  finalized_at timestamptz,
  membership_numbers text
)
language sql security definer set search_path=public stable
as $$
  select mw.id,mw.person_id,p.registered_name,p.display_name,mw.selection_source::text,
         mw.finalized_by,mw.finalized_at,
         string_agg(m.membership_number, ', ' order by m.membership_number)
  from public.monthly_winners mw
  join public.people p on p.id=mw.person_id
  left join public.monthly_winner_memberships mwm on mwm.monthly_winner_id=mw.id
  left join public.memberships m on m.id=mwm.membership_id
  join public.cycles c on c.id=mw.cycle_id
  join public.kuris k on k.id=c.kuri_id
  where mw.cycle_id=target_cycle_id
    and exists (
      select 1 from public.organization_users ou
      where ou.organization_id=k.organization_id and ou.user_id=auth.uid()
        and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    )
  group by mw.id,mw.person_id,p.registered_name,p.display_name,mw.selection_source,mw.finalized_by,mw.finalized_at
  order by mw.finalized_at,mw.id;
$$;

revoke all on function public.finalize_draw_for_admin(uuid,uuid[]) from public;
revoke all on function public.get_monthly_winners_for_admin(uuid) from public;
grant execute on function public.finalize_draw_for_admin(uuid,uuid[]) to authenticated;
grant execute on function public.get_monthly_winners_for_admin(uuid) to authenticated;

commit;