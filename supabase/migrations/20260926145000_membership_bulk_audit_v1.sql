-- SEC-004: audit successful membership creation for bulk/activity visibility.
create or replace function public.audit_membership_creation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_actor uuid := auth.uid();
begin
  select k.organization_id
  into v_org_id
  from public.kuris k
  where k.id = new.kuri_id;

  if v_org_id is null then
    raise exception 'Unable to resolve organization for membership audit event';
  end if;

  insert into public.audit_logs(
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    old_data,
    new_data,
    reason
  )
  values(
    v_org_id,
    v_actor,
    'membership_created',
    'memberships',
    new.id,
    null,
    jsonb_build_object(
      'id', new.id,
      'kuri_id', new.kuri_id,
      'person_id', new.person_id,
      'membership_number', new.membership_number,
      'status', new.status,
      'catch_up_policy', new.catch_up_policy
    ),
    null
  );

  return new;
end;
$$;

drop trigger if exists audit_membership_creation on public.memberships;

create trigger audit_membership_creation
after insert on public.memberships
for each row
execute function public.audit_membership_creation();

revoke all on function public.audit_membership_creation() from public, anon, authenticated;
