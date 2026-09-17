-- Bootstrap the first Kuri-App workspace and MAIN_ADMIN role.
-- The authenticated user's UUID is taken from auth.uid(), so no user ID is stored in Git.

begin;

create or replace function public.bootstrap_kuri_admin(target_organization_name text default 'Kuri-App')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  organization_id uuid;
begin
  if current_user_id is null then
    raise exception 'You must be signed in to bootstrap the Kuri-App workspace.';
  end if;

  if not exists (select 1 from public.users where id = current_user_id) then
    raise exception 'The signed-in Auth user does not have an application user record.';
  end if;

  select ou.organization_id
    into organization_id
  from public.organization_users ou
  where ou.user_id = current_user_id
  limit 1;

  if organization_id is not null then
    insert into public.organization_users (organization_id, user_id, role)
    values (organization_id, current_user_id, 'MAIN_ADMIN')
    on conflict (organization_id, user_id) do update
      set role = 'MAIN_ADMIN';

    return organization_id;
  end if;

  insert into public.organizations (name)
  values (target_organization_name)
  returning id into organization_id;

  insert into public.organization_users (organization_id, user_id, role)
  values (organization_id, current_user_id, 'MAIN_ADMIN');

  return organization_id;
end;
$$;

revoke all on function public.bootstrap_kuri_admin(text) from public;
grant execute on function public.bootstrap_kuri_admin(text) to authenticated;

commit;
