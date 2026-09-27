begin;

create or replace function public.transfer_kuri_main_admin(
  target_kuri_id uuid,
  target_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  caller_user_id uuid := (select auth.uid());
  target_organization_id uuid;
  current_main_admin_user_id uuid;
  main_admin_count integer;
  target_role public.kuri_admin_role;
begin
  if caller_user_id is null then
    raise exception 'Authentication required';
  end if;

  if target_kuri_id is null or target_user_id is null then
    raise exception 'Kuri and target user are required';
  end if;

  select k.organization_id
    into target_organization_id
  from public.kuris k
  where k.id = target_kuri_id
  for update;

  if not found then
    raise exception 'Kuri not found';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'Kuri MAIN_ADMIN role required';
  end if;

  select count(*), min(ka.user_id)
    into main_admin_count, current_main_admin_user_id
  from public.kuri_admins ka
  where ka.kuri_id = target_kuri_id
    and ka.role = 'MAIN_ADMIN';

  if main_admin_count <> 1 then
    raise exception 'Kuri must have exactly one MAIN_ADMIN';
  end if;

  if current_main_admin_user_id <> caller_user_id then
    raise exception 'Only the current Kuri MAIN_ADMIN can transfer authority';
  end if;

  if target_user_id = current_main_admin_user_id then
    raise exception 'Target user is already the MAIN_ADMIN';
  end if;

  select ka.role
    into target_role
  from public.kuri_admins ka
  where ka.kuri_id = target_kuri_id
    and ka.user_id = target_user_id
  for update;

  if not found then
    raise exception 'Target user is not a Kuri administrator';
  end if;

  if target_role <> 'ADMIN' then
    raise exception 'Target user must already be a Kuri ADMIN';
  end if;

  update public.kuri_admins
  set role = 'ADMIN'
  where kuri_id = target_kuri_id
    and user_id = current_main_admin_user_id;

  update public.kuri_admins
  set role = 'MAIN_ADMIN'
  where kuri_id = target_kuri_id
    and user_id = target_user_id;

  insert into public.audit_logs (
    organization_id, user_id, action, entity_type, entity_id,
    old_data, new_data, reason
  )
  values (
    target_organization_id,
    caller_user_id,
    'KURI_MAIN_ADMIN_TRANSFER',
    'kuri_admins',
    target_user_id,
    jsonb_build_object(
      'kuri_id', target_kuri_id,
      'previous_main_admin_user_id', current_main_admin_user_id,
      'previous_target_role', 'ADMIN'
    ),
    jsonb_build_object(
      'kuri_id', target_kuri_id,
      'new_main_admin_user_id', target_user_id,
      'new_caller_role', 'ADMIN'
    ),
    'Kuri MAIN_ADMIN authority transferred by the current Kuri MAIN_ADMIN.'
  );

  return target_user_id;
end;
$function$;

revoke execute on function public.transfer_kuri_main_admin(uuid,uuid) from public, anon;
grant execute on function public.transfer_kuri_main_admin(uuid,uuid) to authenticated;

commit;