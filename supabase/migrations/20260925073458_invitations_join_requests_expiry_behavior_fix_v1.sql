begin;

create or replace function public.accept_kuri_invitation(
  invitation_code text
)
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
  if current_person_id is null then
    raise exception 'Complete your account profile before joining a Kuri.';
  end if;

  select * into invitation_row
  from public.kuri_invitations i
  where i.code_hash=encode(
    extensions.digest(normalized_code,'sha256'),
    'hex'
  )
  for update;

  if not found then raise exception 'Invitation code is invalid.'; end if;
  if invitation_row.status <> 'PENDING' then raise exception 'This invitation is no longer valid.'; end if;
  if invitation_row.expires_at <= now() then raise exception 'This invitation has expired.'; end if;

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

  if not exists (
    select 1 from public.kuris k
    where k.id=invitation_row.kuri_id and k.status in ('OPEN','ACTIVE')
  ) then
    raise exception 'This Kuri is not currently accepting membership.';
  end if;

  if exists (
    select 1 from public.memberships m
    where m.kuri_id=invitation_row.kuri_id
      and m.person_id=current_person_id
      and m.status <> 'EXITED'
  ) then
    raise exception 'You already have a membership in this Kuri.';
  end if;

  insert into public.kuri_join_requests(
    kuri_id,invitation_id,applicant_user_id,applicant_person_id
  )
  values(invitation_row.kuri_id,invitation_row.id,actor_id,current_person_id)
  returning id into request_id;

  update public.kuri_invitations
  set status='CONSUMED',consumed_at=now(),consumed_by=actor_id
  where id=invitation_row.id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select
    k.organization_id,actor_id,'JOIN_REQUEST_CREATED','KURI_JOIN_REQUEST',request_id,
    jsonb_build_object(
      'kuri_id',invitation_row.kuri_id,
      'invitation_id',invitation_row.id,
      'applicant_person_id',current_person_id
    ),
    'Invitation accepted; membership remains pending admin approval'
  from public.kuris k where k.id=invitation_row.kuri_id;

  return request_id;
end;
$function$;

revoke all on function public.accept_kuri_invitation(text) from public,anon;
grant execute on function public.accept_kuri_invitation(text) to authenticated;

commit;