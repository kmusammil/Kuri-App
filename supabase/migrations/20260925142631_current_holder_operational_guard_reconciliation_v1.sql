begin;

create or replace function public.enforce_membership_current_holder_identity()
returns trigger language plpgsql security definer set search_path=''
as $function$
declare v_kuri_org_id uuid; v_holder_org_id uuid;
begin
  if new.current_holder_person_id is null then return new; end if;
  if new.current_holder_person_id=new.person_id then
    raise exception 'Current holder must differ from the original member identity.';
  end if;
  select k.organization_id into v_kuri_org_id from public.kuris k where k.id=new.kuri_id;
  select p.organization_id into v_holder_org_id from public.people p where p.id=new.current_holder_person_id;
  if v_kuri_org_id is null or v_holder_org_id is null or v_kuri_org_id<>v_holder_org_id then
    raise exception 'Current holder does not belong to the Kuri organization.';
  end if;
  if not exists(
    select 1 from public.membership_successions s
    where s.membership_id=new.id and s.successor_person_id=new.current_holder_person_id
  ) then
    raise exception 'Current holder can only be changed through a recorded succession.';
  end if;
  if tg_op='UPDATE' and old.current_holder_person_id is not null
     and old.current_holder_person_id<>new.current_holder_person_id then
    raise exception 'Current holder is immutable after succession.';
  end if;
  return new;
end
$function$;

drop trigger if exists membership_current_holder_identity_guard on public.memberships;
create trigger membership_current_holder_identity_guard
before insert or update of current_holder_person_id on public.memberships
for each row execute function public.enforce_membership_current_holder_identity();

revoke all on function public.enforce_membership_current_holder_identity() from public,anon,authenticated;

commit;