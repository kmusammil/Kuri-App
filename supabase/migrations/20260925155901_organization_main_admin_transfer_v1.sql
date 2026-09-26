begin;

create or replace function public.transfer_organization_main_admin(
  target_organization_id uuid,
  target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  caller_user_id uuid := (select auth.uid());
  current_main_admin_user_id uuid;
  main_admin_count integer;
  target_role public.app_role;
begin
  if caller_user_id is null then
    raise exception 'Authentication required';
  end if;

  if target_organization_id is null or target_user_id is null then
    raise exception 'Organization and target user are required';
  end if;

  perform 1
  from public.organizations o
  where o.id = target_organization_id
  for update;

  if not found then
    raise exception 'Organization not found';
  end if;

  if not public.has_org_role(
    target_organization_id,
    array['MAIN_ADMIN']::public.app_role[]
  ) then
    raise exception 'Organization MAIN_ADMIN role required';
  end if;

  select count(*), min(ou.user_id)
    into main_admin_count, current_main_admin_user_id
  from public.organization_users ou
  where ou.organization_id = target_organization_id
    and ou.role = 'MAIN_ADMIN';

  if main_admin_count <> 1 then
    raise exception 'Organization must have exactly one MAIN_ADMIN';
  end if;

  if current_main_admin_user_id <> caller_user_id then
    raise exception 'Only the current MAIN_ADMIN can transfer authority';
  end if;

  if target_user_id = current_main_admin_user_id then
    raise exception 'Target user is already the MAIN_ADMIN';
  end if;

  select ou.role
    into target_role
  from public.organization_users ou
  where ou.organization_id = target_organization_id
    and ou.user_id = target_user_id
  for update;

  if not found then
    raise exception 'Target user is not an organization member';
  end if;

  if target_role <> 'ADMIN' then
    raise exception 'Target user must already be an organization ADMIN';
  end if;

  update public.organization_users
  set role = 'ADMIN'
  where organization_id = target_organization_id
    and user_id = current_main_admin_user_id;

  update public.organization_users
  set role = 'MAIN_ADMIN'
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.audit_logs (
    organization_id, user_id, action, entity_type, entity_id,
    old_data, new_data, reason
  )
  values (
    target_organization_id,
    caller_user_id,
    'ORGANIZATION_MAIN_ADMIN_TRANSFER',
    'organization_users',
    target_user_id,
    jsonb_build_object(
      'previous_main_admin_user_id', current_main_admin_user_id,
      'previous_target_role', 'ADMIN'
    ),
    jsonb_build_object(
      'new_main_admin_user_id', target_user_id,
      'new_caller_role', 'ADMIN'
    ),
    'Organization MAIN_ADMIN authority transferred by the current MAIN_ADMIN.'
  );

  return target_user_id;
end;
$function$;

revoke execute on function public.transfer_organization_main_admin(uuid,uuid) from public, anon;
grant execute on function public.transfer_organization_main_admin(uuid,uuid) to authenticated;

commit;