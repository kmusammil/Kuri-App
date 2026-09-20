begin;

-- Create a person and optional primary contact records atomically through a
-- SECURITY DEFINER admin RPC. The function validates the signed-in user's
-- workspace role before touching the global people registry.
create or replace function public.create_person_for_admin(
  registered_name text,
  display_name text default null,
  address text default null,
  notes text default null,
  phone text default null,
  email text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  person_id uuid;
  clean_registered_name text := nullif(trim(registered_name), '');
  clean_display_name text := nullif(trim(display_name), '');
  clean_address text := nullif(trim(address), '');
  clean_notes text := nullif(trim(notes), '');
  clean_phone text := nullif(trim(phone), '');
  clean_email text := nullif(trim(email), '');
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to add people.';
  end if;

  if clean_registered_name is null then
    raise exception 'Registered name is required.';
  end if;

  insert into public.people (
    registered_name,
    display_name,
    address,
    notes
  )
  values (
    clean_registered_name,
    clean_display_name,
    clean_address,
    clean_notes
  )
  returning id into person_id;

  if clean_phone is not null then
    insert into public.person_phones (
      person_id,
      phone_number,
      is_primary
    )
    values (
      person_id,
      clean_phone,
      true
    );
  end if;

  if clean_email is not null then
    insert into public.person_emails (
      person_id,
      email,
      is_primary
    )
    values (
      person_id,
      clean_email,
      true
    );
  end if;

  return person_id;
end;
$$;

revoke all on function public.create_person_for_admin(text,text,text,text,text,text) from public;
grant execute on function public.create_person_for_admin(text,text,text,text,text,text) to authenticated;

commit;
