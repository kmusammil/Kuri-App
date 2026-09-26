begin;
revoke all on function public.link_nominee_to_successor_person_for_admin(uuid,uuid,uuid) from public,anon;
revoke all on function public.record_membership_succession_for_admin(uuid,uuid,text) from public,anon;
revoke all on function public.enforce_nominee_successor_identity() from public,anon,authenticated;
grant execute on function public.link_nominee_to_successor_person_for_admin(uuid,uuid,uuid) to authenticated;
grant execute on function public.record_membership_succession_for_admin(uuid,uuid,text) to authenticated;
commit;
