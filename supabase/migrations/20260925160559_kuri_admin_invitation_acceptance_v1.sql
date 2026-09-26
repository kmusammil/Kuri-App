begin;

alter table public.kuri_invitations
  add column if not exists invitation_type text not null default 'MEMBERSHIP';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'kuri_invitations_invitation_type_check'
      and conrelid = 'public.kuri_invitations'::regclass
  ) then
    alter table public.kuri_invitations
      add constraint kuri_invitations_invitation_type_check
      check (invitation_type in ('MEMBERSHIP','ADMIN'));
  end if;
end;
$$;

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
    where k.id = target_kuri_id
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
     and exists (select 1 from public.kuri_admins where kuri_id=target_kuri_id and user_id=target_recipient_user_id) then
    raise exception 'Recipient is already a Kuri administrator.';
  end if;

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

create or replace function public.accept_kuri_admin_invitation(
  invitation_code text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  actor_id uuid := (select auth.uid());
  invitation_row public.kuri_invitations%rowtype;
begin
  if actor_id is null then
    raise exception 'You must be signed in.';
  end if;

  select *
  into invitation_row
  from public.kuri_invitations i
  where i.code_hash = encode(
    extensions.digest(
      replace(upper(trim(coalesce(invitation_code,''))),'-',''),
      'sha256'
    ),
    'hex'
  )
  for update;

  if not found then raise exception 'Invitation code is invalid.'; end if;
  if invitation_row.invitation_type <> 'ADMIN' then
    raise exception 'This invitation is not a Kuri administrator invitation.';
  end if;
  if invitation_row.status <> 'PENDING' then
    raise exception 'This invitation is no longer valid.';
  end if;
  if invitation_row.expires_at <= now() then
    raise exception 'This invitation has expired.';
  end if;

  if invitation_row.recipient_user_id is not null
     and invitation_row.recipient_user_id <> actor_id then
    raise exception 'This invitation is not assigned to this account.';
  end if;

  if invitation_row.recipient_email is not null
     and lower(coalesce((select u.email from public.users u where u.id=actor_id),'')) <> invitation_row.recipient_email then
    raise exception 'This invitation is assigned to a different email address.';
  end if;

  if invitation_row.recipient_phone is not null
     and coalesce((select u.phone from public.users u where u.id=actor_id),'') <> invitation_row.recipient_phone then
    raise exception 'This invitation is assigned to a different phone number.';
  end if;

  if exists (
    select 1 from public.kuri_admins ka
    where ka.kuri_id = invitation_row.kuri_id
      and ka.user_id = actor_id
  ) then
    raise exception 'You are already a Kuri administrator.';
  end if;

  if not exists (
    select 1 from public.kuris k
    where k.id = invitation_row.kuri_id
      and k.status in ('DRAFT','OPEN','ACTIVE')
  ) then
    raise exception 'This Kuri is not available for administrator onboarding.';
  end if;

  insert into public.kuri_admins(kuri_id,user_id,role)
  values(invitation_row.kuri_id,actor_id,'ADMIN');

  update public.kuri_invitations
  set status='CONSUMED',consumed_at=now(),consumed_by=actor_id
  where id=invitation_row.id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select k.organization_id,actor_id,'KURI_ADMIN_INVITATION_ACCEPTED','KURI_ADMIN',actor_id,
    jsonb_build_object(
      'kuri_id',invitation_row.kuri_id,
      'invitation_id',invitation_row.id,
      'role','ADMIN'
    ),
    'Kuri administrator invitation accepted'
  from public.kuris k
  where k.id=invitation_row.kuri_id;

  return actor_id;
end;
$function$;

revoke execute on function public.create_kuri_admin_invitation_for_admin(uuid,uuid,text,text,timestamptz) from public, anon;
grant execute on function public.create_kuri_admin_invitation_for_admin(uuid,uuid,text,text,timestamptz) to authenticated;
revoke execute on function public.accept_kuri_admin_invitation(text) from public, anon;
grant execute on function public.accept_kuri_admin_invitation(text) to authenticated;

commit;