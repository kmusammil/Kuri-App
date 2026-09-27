begin;

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
  normalized_email text := nullif(lower(trim(target_recipient_email)), '');
  normalized_phone text := nullif(trim(target_recipient_phone), '');
  expiry timestamptz := coalesce(target_expires_at, now() + interval '7 days');
  issuer_id uuid := (select auth.uid());
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

  loop
    plain_code :=
      'KURI-' || (
        select string_agg(
          substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', floor(random()*32)::int + 1, 1),
          ''
        ) from generate_series(1,8)
      );
    exit when not exists (
      select 1 from public.kuri_invitations
      where code_hash = encode(
        extensions.digest(replace(upper(plain_code),'-',''),'sha256'),'hex'
      )
    );
  end loop;

  insert into public.kuri_invitations(
    kuri_id,issued_by,recipient_user_id,recipient_email,recipient_phone,code_hash,expires_at
  )
  values(
    target_kuri_id,issuer_id,target_recipient_user_id,normalized_email,normalized_phone,
    encode(extensions.digest(replace(upper(plain_code),'-',''),'sha256'),'hex'),
    expiry
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

  return jsonb_build_object('invitation_id',invitation_id,'code',plain_code,'expires_at',expiry);
end;
$function$;

create or replace function public.accept_kuri_invitation(invitation_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  actor_id uuid := (select auth.uid());
  current_person_id uuid;
  invitation_row public.kuri_invitations%rowtype;
  request_id uuid;
  normalized_code text := replace(upper(trim(coalesce(invitation_code,''))),'-','');
begin
  if actor_id is null then raise exception 'You must be signed in.'; end if;
  select u.person_id into current_person_id from public.users u where u.id=actor_id;
  if current_person_id is null then raise exception 'Complete your account profile before joining a Kuri.'; end if;

  select * into invitation_row from public.kuri_invitations i
  where i.code_hash=encode(extensions.digest(normalized_code,'sha256'),'hex')
  for update;

  if not found then raise exception 'Invitation code is invalid.'; end if;
  if invitation_row.status <> 'PENDING' then raise exception 'This invitation is no longer valid.'; end if;
  if invitation_row.expires_at <= now() then raise exception 'This invitation has expired.'; end if;
  if invitation_row.recipient_user_id is not null and invitation_row.recipient_user_id <> actor_id then
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
  if not exists (
    select 1 from public.kuris k where k.id=invitation_row.kuri_id and k.status in ('OPEN','ACTIVE')
  ) then raise exception 'This Kuri is not currently accepting membership.'; end if;
  if exists (
    select 1 from public.memberships m
    where m.kuri_id=invitation_row.kuri_id and m.person_id=current_person_id and m.status <> 'EXITED'
  ) then raise exception 'You already have a membership in this Kuri.'; end if;

  insert into public.kuri_join_requests(kuri_id,invitation_id,applicant_user_id,applicant_person_id)
  values(invitation_row.kuri_id,invitation_row.id,actor_id,current_person_id)
  returning id into request_id;

  update public.kuri_invitations
  set status='CONSUMED',consumed_at=now(),consumed_by=actor_id
  where id=invitation_row.id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select k.organization_id,actor_id,'JOIN_REQUEST_CREATED','KURI_JOIN_REQUEST',request_id,
    jsonb_build_object('kuri_id',invitation_row.kuri_id,'invitation_id',invitation_row.id,'applicant_person_id',current_person_id),
    'Invitation accepted; membership remains pending admin approval'
  from public.kuris k where k.id=invitation_row.kuri_id;

  return request_id;
end;
$function$;

revoke all on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) from public,anon;
grant execute on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) to authenticated;
revoke all on function public.accept_kuri_invitation(text) from public,anon;
grant execute on function public.accept_kuri_invitation(text) to authenticated;

commit;