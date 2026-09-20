-- Cleanup for disposable positive integration fixtures.
-- Run manually in the Supabase SQL editor after the positive workflow tests.
-- This targets only Kuri records named "Integration E2E <timestamp>" inside
-- the dedicated "Kuri-App Integration Test A" organization.

begin;

create temporary table _e2e_cleanup_kuris on commit drop as
select k.id
from public.kuris k
join public.organizations o on o.id = k.organization_id
where o.name = 'Kuri-App Integration Test A'
  and k.name like 'Integration E2E %';

create temporary table _e2e_cleanup_cycles on commit drop as
select c.id
from public.cycles c
join _e2e_cleanup_kuris k on k.id = c.kuri_id;

create temporary table _e2e_cleanup_memberships on commit drop as
select m.id
from public.memberships m
join _e2e_cleanup_kuris k on k.id = m.kuri_id;

create temporary table _e2e_cleanup_payments on commit drop as
select p.id
from public.payments p
join _e2e_cleanup_memberships m on m.id = p.person_id
where false;

-- Payments are linked to people rather than memberships, so identify the
-- disposable person through the membership set and its test person ID.
delete from public.payment_allocations pa
using public.payments p
where pa.payment_id = p.id
  and p.reference_number like 'E2E-%';

delete from public.payouts p
using public.monthly_winners w
where p.monthly_winner_id = w.id
  and w.cycle_id in (select id from _e2e_cleanup_cycles);

delete from public.monthly_winner_memberships mwm
using public.monthly_winners w
where mwm.monthly_winner_id = w.id
  and w.cycle_id in (select id from _e2e_cleanup_cycles);

delete from public.monthly_winners
where cycle_id in (select id from _e2e_cleanup_cycles);

delete from public.draw_selections
where draw_session_id in (
  select id from public.draw_sessions
  where cycle_id in (select id from _e2e_cleanup_cycles)
);

delete from public.draw_pool_entries
where draw_session_id in (
  select id from public.draw_sessions
  where cycle_id in (select id from _e2e_cleanup_cycles)
);

delete from public.draw_sessions
where cycle_id in (select id from _e2e_cleanup_cycles);

delete from public.muppu_records
where cycle_id in (select id from _e2e_cleanup_cycles);

delete from public.installments
where membership_id in (select id from _e2e_cleanup_memberships);

delete from public.memberships
where id in (select id from _e2e_cleanup_memberships);

delete from public.cycles
where id in (select id from _e2e_cleanup_cycles);

delete from public.kuris
where id in (select id from _e2e_cleanup_kuris);

commit;
