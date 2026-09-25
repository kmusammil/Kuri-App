begin;

create or replace function public.has_kuri_admin_role(
  target_kuri uuid,
  target_roles public.kuri_admin_role[]
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.kuri_admins ka
    join public.kuris k on k.id = ka.kuri_id
    join public.organization_users ou
      on ou.organization_id = k.organization_id
     and ou.user_id = ka.user_id
    where ka.kuri_id = target_kuri
      and ka.user_id = (select auth.uid())
      and ka.role = any(target_roles)
  );
$$;

create or replace function public.create_kuri_invitation_for_admin(
  target_kuri_id uuid,
  target_recipient_user_id uuid default null,
  target_recipient_email text default null,
  target_recipient_phone text default null,
  target_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  invitation_id uuid;
  plain_code text;
  random_hex text;
  normalized_email text := nullif(lower(trim(target_recipient_email)), '');
  normalized_phone text := nullif(trim(target_recipient_phone)), '';
  expiry timestamptz := coalesce(target_expires_at, now() + interval '7 days');
  issuer_id uuid := (select auth.uid());
begin
  if issuer_id is null then
    raise exception 'You must be signed in.';
  end if;

  if not exists (
    select 1 from public.kuris k
    where k.id=target_kuri_id
      and public.has_kuri_admin_role(
        k.id,
        array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
      )
  ) then
    raise exception 'You do not have Kuri administration permission.';
  end if;

  if num_nonnulls(target_recipient_user_id,normalized_email,normalized_phone) <> 1 then
    raise exception 'Exactly one invitation recipient is required: user, email, or phone.';
  end if;

  if expiry <= now() then
    raise exception 'Invitation expiry must be in the future.';
  end if;

  if target_recipient_user_id is not null
     and not exists (select 1 from public.users where id=target_recipient_user_id) then
    raise exception 'Recipient user was not found.';
  end if;

  loop
    random_hex := upper(encode(extensions.gen_random_bytes(8),'hex'));
    plain_code :=
      'KURI-' ||
      substr(random_hex,1,4) || '-' ||
      substr(random_hex,5,4) || '-' ||
      substr(random_hex,9,4) || '-' ||
      substr(random_hex,13,4);

    exit when not exists (
      select 1
      from public.kuri_invitations
      where code_hash = encode(
        extensions.digest(replace(upper(plain_code),'-',''),'sha256'),
        'hex'
      )
    );
  end loop;

  insert into public.kuri_invitations(
    kuri_id,issued_by,recipient_user_id,recipient_email,recipient_phone,
    code_hash,expires_at
  )
  values(
    target_kuri_id,issuer_id,target_recipient_user_id,normalized_email,normalized_phone,
    encode(
      extensions.digest(replace(upper(plain_code),'-',''),'sha256'),
      'hex'
    ),
    expiry
  )
  returning id into invitation_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select
    k.organization_id,issuer_id,'INVITATION_CREATED','KURI_INVITATION',invitation_id,
    jsonb_build_object(
      'kuri_id',target_kuri_id,
      'recipient_user_id',target_recipient_user_id,
      'recipient_email',normalized_email,
      'recipient_phone',normalized_phone,
      'expires_at',expiry
    ),
    'Kuri invitation issued'
  from public.kuris k where k.id=target_kuri_id;

  return jsonb_build_object(
    'invitation_id',invitation_id,
    'code',plain_code,
    'expires_at',expiry
  );
end;
$function$;

revoke all on function public.has_kuri_admin_role(uuid,public.kuri_admin_role[]) from public,anon;
grant execute on function public.has_kuri_admin_role(uuid,public.kuri_admin_role[]) to authenticated;
revoke all on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) from public,anon;
grant execute on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) to authenticated;

commit;