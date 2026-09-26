begin;

create table if not exists public.kuri_invitation_rate_limits (
  issuer_user_id uuid primary key,
  window_started_at timestamptz not null default now(),
  invitation_count integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.kuri_invitation_rate_limits enable row level security;

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
set search_path = ''
as $function$
declare
  invitation_id uuid;
  plain_code text;
  random_hex text;
  normalized_email text := nullif(lower(trim(target_recipient_email)), '');
  normalized_phone text := nullif(trim(target_recipient_phone), '');
  expiry timestamptz := coalesce(target_expires_at, now() + interval '7 days');
  issuer_id uuid := (select auth.uid());
  window_started timestamptz;
  invitation_count integer;
begin
  if issuer_id is null then raise exception 'You must be signed in.'; end if;

  if not exists (
    select 1 from public.kuris k
    where k.id=target_kuri_id
      and public.has_kuri_admin_role(k.id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ) then raise exception 'You do not have Kuri administration permission.'; end if;

  if num_nonnulls(target_recipient_user_id,normalized_email,normalized_phone) <> 1 then
    raise exception 'Exactly one invitation recipient is required: user, email, or phone.';
  end if;

  if expiry <= now() then raise exception 'Invitation expiry must be in the future.'; end if;

  if target_recipient_user_id is not null
     and not exists (select 1 from public.users where id=target_recipient_user_id) then
    raise exception 'Recipient user was not found.';
  end if;

  insert into public.kuri_invitation_rate_limits(issuer_user_id)
  values (issuer_id)
  on conflict (issuer_user_id) do nothing;

  select window_started_at, invitation_count
    into window_started, invitation_count
  from public.kuri_invitation_rate_limits
  where issuer_user_id=issuer_id
  for update;

  if window_started <= now() - interval '1 hour' then
    update public.kuri_invitation_rate_limits
    set window_started_at=now(), invitation_count=0, updated_at=now()
    where issuer_user_id=issuer_id;
    invitation_count := 0;
  end if;

  if invitation_count >= 50 then
    raise exception 'Invitation rate limit exceeded. Please try again later.';
  end if;

  update public.kuri_invitation_rate_limits
  set invitation_count=invitation_count+1, updated_at=now()
  where issuer_user_id=issuer_id;

  loop
    random_hex := upper(encode(extensions.gen_random_bytes(8),'hex'));
    plain_code := 'KURI-' || substr(random_hex,1,4) || '-' ||
      substr(random_hex,5,4) || '-' || substr(random_hex,9,4) || '-' || substr(random_hex,13,4);
    exit when not exists (
      select 1 from public.kuri_invitations
      where code_hash=encode(extensions.digest(replace(upper(plain_code),'-',''),'sha256'),'hex')
    );
  end loop;

  insert into public.kuri_invitations(
    kuri_id,issued_by,recipient_user_id,recipient_email,recipient_phone,
    code_hash,expires_at,invitation_type
  )
  values(
    target_kuri_id,issuer_id,target_recipient_user_id,normalized_email,normalized_phone,
    encode(extensions.digest(replace(upper(plain_code),'-',''),'sha256'),'hex'),
    expiry,'MEMBERSHIP'
  )
  returning id into invitation_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select k.organization_id,issuer_id,'INVITATION_CREATED','KURI_INVITATION',invitation_id,
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
    'invitation_id',invitation_id,'code',plain_code,'expires_at',expiry
  );
end;
$function$;

create or replace function public.create_kuri_admin_invitation_for_admin(
  target_kuri_id uuid,
  target_recipient_user_id uuid default null,
  target_recipient_email text default null,
  target_recipient_phone text default null,
  target_expires_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  invitation_id uuid;
  plain_code text;
  random_hex text;
  normalized_email text := nullif(lower(trim(target_recipient_email)), '');
  normalized_phone text := nullif(trim(target_recipient_phone), '');
  expiry timestamptz := coalesce(target_expires_at, now() + interval '7 days');
  issuer_id uuid := (select auth.uid());
  window_started timestamptz;
  invitation_count integer;
begin
  if issuer_id is null then raise exception 'You must be signed in.'; end if;

  if not exists (
    select 1 from public.kuris k
    where k.id=target_kuri_id
      and public.has_kuri_admin_role(k.id,array['MAIN_ADMIN']::public.kuri_admin_role[])
  ) then raise exception 'Only the Kuri MAIN_ADMIN can invite a Kuri administrator.'; end if;

  if num_nonnulls(target_recipient_user_id,normalized_email,normalized_phone) <> 1 then
    raise exception 'Exactly one invitation recipient is required: user, email, or phone.';
  end if;

  if expiry <= now() then raise exception 'Invitation expiry must be in the future.'; end if;

  if target_recipient_user_id is not null
     and not exists (select 1 from public.users where id=target_recipient_user_id) then
    raise exception 'Recipient user was not found.';
  end if;

  if target_recipient_user_id is not null
     and exists (
       select 1 from public.kuri_admins
       where kuri_id=target_kuri_id and user_id=target_recipient_user_id
     ) then
    raise exception 'Recipient is already a Kuri administrator.';
  end if;

  insert into public.kuri_invitation_rate_limits(issuer_user_id)
  values (issuer_id)
  on conflict (issuer_user_id) do nothing;

  select window_started_at, invitation_count
    into window_started, invitation_count
  from public.kuri_invitation_rate_limits
  where issuer_user_id=issuer_id
  for update;

  if window_started <= now() - interval '1 hour' then
    update public.kuri_invitation_rate_limits
    set window_started_at=now(), invitation_count=0, updated_at=now()
    where issuer_user_id=issuer_id;
    invitation_count := 0;
  end if;

  if invitation_count >= 50 then
    raise exception 'Invitation rate limit exceeded. Please try again later.';
  end if;

  update public.kuri_invitation_rate_limits
  set invitation_count=invitation_count+1, updated_at=now()
  where issuer_user_id=issuer_id;

  loop
    random_hex := upper(encode(extensions.gen_random_bytes(8),'hex'));
    plain_code := 'KURI-ADMIN-' || substr(random_hex,1,4) || '-' ||
      substr(random_hex,5,4) || '-' || substr(random_hex,9,4) || '-' || substr(random_hex,13,4);
    exit when not exists (
      select 1 from public.kuri_invitations
      where code_hash=encode(extensions.digest(replace(upper(plain_code),'-',''),'sha256'),'hex')
    );
  end loop;

  insert into public.kuri_invitations(
    kuri_id,issued_by,recipient_user_id,recipient_email,recipient_phone,
    code_hash,expires_at,invitation_type
  )
  values(
    target_kuri_id,issuer_id,target_recipient_user_id,normalized_email,normalized_phone,
    encode(extensions.digest(replace(upper(plain_code),'-',''),'sha256'),'hex'),
    expiry,'ADMIN'
  )
  returning id into invitation_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select k.organization_id,issuer_id,'KURI_ADMIN_INVITATION_CREATED','KURI_INVITATION',invitation_id,
    jsonb_build_object(
      'kuri_id',target_kuri_id,
      'recipient_user_id',target_recipient_user_id,
      'recipient_email',normalized_email,
      'recipient_phone',normalized_phone,
      'expires_at',expiry,
      'invitation_type','ADMIN'
    ),
    'Kuri administrator invitation issued'
  from public.kuris k where k.id=target_kuri_id;

  return jsonb_build_object(
    'invitation_id',invitation_id,'code',plain_code,'expires_at',expiry
  );
end;
$function$;

revoke execute on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) from public, anon;
grant execute on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) to authenticated;
revoke execute on function public.create_kuri_admin_invitation_for_admin(uuid,uuid,text,text,timestamptz) from public, anon;
grant execute on function public.create_kuri_admin_invitation_for_admin(uuid,uuid,text,text,timestamptz) to authenticated;

commit;