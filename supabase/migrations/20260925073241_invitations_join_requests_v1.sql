begin;

do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='invitation_status'
  ) then
    create type public.invitation_status as enum ('PENDING','REVOKED','CONSUMED','EXPIRED');
  end if;

  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typname='join_request_status'
  ) then
    create type public.join_request_status as enum ('PENDING','APPROVED','REJECTED');
  end if;
end
$$;

create table if not exists public.kuri_invitations (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete cascade,
  issued_by uuid not null references public.users(id) on delete restrict,
  recipient_user_id uuid references public.users(id) on delete set null,
  recipient_email text,
  recipient_phone text,
  code_hash text not null unique,
  expires_at timestamptz not null,
  status public.invitation_status not null default 'PENDING',
  consumed_at timestamptz,
  consumed_by uuid references public.users(id) on delete set null,
  revoked_at timestamptz,
  revoked_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (num_nonnulls(recipient_user_id, recipient_email, recipient_phone) = 1),
  check (expires_at > created_at),
  check (
    (status='PENDING' and consumed_at is null and revoked_at is null)
    or (status='REVOKED' and revoked_at is not null and consumed_at is null)
    or (status='CONSUMED' and consumed_at is not null)
    or (status='EXPIRED' and consumed_at is null)
  )
);

create index if not exists kuri_invitations_kuri_status_idx
  on public.kuri_invitations(kuri_id,status,created_at desc);
create index if not exists kuri_invitations_recipient_user_idx
  on public.kuri_invitations(recipient_user_id)
  where recipient_user_id is not null;
create index if not exists kuri_invitations_recipient_email_idx
  on public.kuri_invitations(lower(recipient_email))
  where recipient_email is not null;
create index if not exists kuri_invitations_recipient_phone_idx
  on public.kuri_invitations(recipient_phone)
  where recipient_phone is not null;

create table if not exists public.kuri_join_requests (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete cascade,
  invitation_id uuid references public.kuri_invitations(id) on delete set null,
  applicant_user_id uuid not null references public.users(id) on delete cascade,
  applicant_person_id uuid not null references public.people(id) on delete restrict,
  status public.join_request_status not null default 'PENDING',
  requested_at timestamptz not null default now(),
  reviewed_by uuid references public.users(id) on delete set null,
  reviewed_at timestamptz,
  rejection_reason text,
  membership_id uuid references public.memberships(id) on delete set null,
  created_at timestamptz not null default now(),
  check (
    (status='PENDING' and reviewed_by is null and reviewed_at is null and membership_id is null)
    or (status='APPROVED' and reviewed_by is not null and reviewed_at is not null and membership_id is not null)
    or (status='REJECTED' and reviewed_by is not null and reviewed_at is not null and membership_id is null)
  )
);

create unique index if not exists kuri_join_requests_one_pending_key
  on public.kuri_join_requests(kuri_id,applicant_user_id)
  where status='PENDING';

create index if not exists kuri_join_requests_kuri_status_idx
  on public.kuri_join_requests(kuri_id,status,requested_at desc);
create index if not exists kuri_join_requests_applicant_idx
  on public.kuri_join_requests(applicant_user_id,requested_at desc);

alter table public.kuri_invitations enable row level security;
alter table public.kuri_join_requests enable row level security;

drop policy if exists kuri_invitations_select on public.kuri_invitations;
create policy kuri_invitations_select
  on public.kuri_invitations
  for select
  to authenticated
  using (
    public.has_kuri_admin_role(
      kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
    or recipient_user_id = (select auth.uid())
    or (
      recipient_email is not null
      and lower(recipient_email) = lower(coalesce((select u.email from public.users u where u.id=(select auth.uid())), ''))
    )
    or (
      recipient_phone is not null
      and recipient_phone = coalesce((select u.phone from public.users u where u.id=(select auth.uid())), '')
    )
  );

drop policy if exists kuri_join_requests_select on public.kuri_join_requests;
create policy kuri_join_requests_select
  on public.kuri_join_requests
  for select
  to authenticated
  using (
    applicant_user_id = (select auth.uid())
    or public.has_kuri_admin_role(
      kuri_id,
      array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  );

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
    plain_code :=
      'KURI-' ||
      (
        select string_agg(
          substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', floor(random()*32)::int + 1, 1),
          ''
        )
        from generate_series(1,8)
      );
    exit when not exists (
      select 1
      from public.kuri_invitations
      where code_hash = encode(digest(replace(upper(plain_code),'-',''),'sha256'),'hex')
    );
  end loop;

  insert into public.kuri_invitations(
    kuri_id,issued_by,recipient_user_id,recipient_email,recipient_phone,
    code_hash,expires_at
  )
  values(
    target_kuri_id,issuer_id,target_recipient_user_id,normalized_email,normalized_phone,
    encode(digest(replace(upper(plain_code),'-',''),'sha256'),'hex'),
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
  from public.kuris k
  where k.id=target_kuri_id;

  return jsonb_build_object(
    'invitation_id',invitation_id,
    'code',plain_code,
    'expires_at',expiry
  );
end;
$function$;

create or replace function public.revoke_kuri_invitation_for_admin(
  target_invitation_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  invitation_row public.kuri_invitations%rowtype;
  actor_id uuid := (select auth.uid());
begin
  if actor_id is null then raise exception 'You must be signed in.'; end if;

  select * into invitation_row from public.kuri_invitations i
  where i.id=target_invitation_id for update;

  if not found then raise exception 'Invitation not found.'; end if;

  if not public.has_kuri_admin_role(
    invitation_row.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have Kuri administration permission.';
  end if;

  if invitation_row.status <> 'PENDING' then
    raise exception 'Only pending invitations can be revoked.';
  end if;

  update public.kuri_invitations
  set status='REVOKED', revoked_at=now(), revoked_by=actor_id
  where id=target_invitation_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,actor_id,'INVITATION_REVOKED','KURI_INVITATION',invitation_row.id,
    jsonb_build_object('status',invitation_row.status),
    jsonb_build_object('status','REVOKED'),
    'Kuri invitation revoked'
  from public.kuris k
  where k.id=invitation_row.kuri_id;
end;
$function$;

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
  where i.code_hash=encode(digest(normalized_code,'sha256'),'hex')
  for update;

  if not found then raise exception 'Invitation code is invalid.'; end if;
  if invitation_row.status <> 'PENDING' then raise exception 'This invitation is no longer valid.'; end if;

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

  if not exists (
    select 1 from public.kuris k where k.id=invitation_row.kuri_id and k.status in ('OPEN','ACTIVE')
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

create or replace function public.list_kuri_join_requests_for_admin(target_kuri_id uuid)
returns table(
  id uuid,kuri_id uuid,applicant_user_id uuid,applicant_person_id uuid,
  status public.join_request_status,requested_at timestamptz,
  reviewed_by uuid,reviewed_at timestamptz,rejection_reason text,membership_id uuid
)
language sql security definer set search_path = public stable
as $function$
  select r.id,r.kuri_id,r.applicant_user_id,r.applicant_person_id,
         r.status,r.requested_at,r.reviewed_by,r.reviewed_at,
         r.rejection_reason,r.membership_id
  from public.kuri_join_requests r
  where r.kuri_id=target_kuri_id
    and public.has_kuri_admin_role(
      r.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by r.requested_at desc;
$function$;

create or replace function public.list_kuri_invitations_for_admin(target_kuri_id uuid)
returns table(
  id uuid,kuri_id uuid,issued_by uuid,recipient_user_id uuid,
  recipient_email text,recipient_phone text,expires_at timestamptz,
  status public.invitation_status,consumed_at timestamptz,
  revoked_at timestamptz,created_at timestamptz
)
language sql security definer set search_path = public stable
as $function$
  select i.id,i.kuri_id,i.issued_by,i.recipient_user_id,
         i.recipient_email,i.recipient_phone,i.expires_at,
         case
           when i.status='PENDING' and i.expires_at <= now()
             then 'EXPIRED'::public.invitation_status
           else i.status
         end,
         i.consumed_at,i.revoked_at,i.created_at
  from public.kuri_invitations i
  where i.kuri_id=target_kuri_id
    and public.has_kuri_admin_role(
      i.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  order by i.created_at desc;
$function$;

create or replace function public.approve_kuri_join_request_for_admin(
  target_request_id uuid,
  target_membership_number text
)
returns uuid
language plpgsql security definer set search_path = public
as $function$
declare
  request_row public.kuri_join_requests%rowtype;
  actor_id uuid := (select auth.uid());
  membership_id_value uuid;
begin
  if actor_id is null then raise exception 'You must be signed in.'; end if;

  select * into request_row from public.kuri_join_requests r
  where r.id=target_request_id for update;

  if not found then raise exception 'Join request not found.'; end if;

  if not public.has_kuri_admin_role(
    request_row.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have Kuri administration permission.';
  end if;

  if request_row.status <> 'PENDING' then
    raise exception 'Only pending join requests can be approved.';
  end if;

  if nullif(btrim(target_membership_number),'') is null then
    raise exception 'Membership number is required for approval.';
  end if;

  membership_id_value := public.create_membership_for_admin(
    request_row.kuri_id,request_row.applicant_person_id,target_membership_number
  );

  update public.kuri_join_requests
  set status='APPROVED',reviewed_by=actor_id,reviewed_at=now(),
      membership_id=membership_id_value
  where id=target_request_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select
    k.organization_id,actor_id,'JOIN_REQUEST_APPROVED','KURI_JOIN_REQUEST',request_row.id,
    jsonb_build_object(
      'status','APPROVED',
      'membership_id',membership_id_value,
      'membership_number',target_membership_number
    ),
    'Join request approved and membership created'
  from public.kuris k where k.id=request_row.kuri_id;

  return membership_id_value;
end;
$function$;

create or replace function public.reject_kuri_join_request_for_admin(
  target_request_id uuid,
  rejection_reason_text text
)
returns void
language plpgsql security definer set search_path = public
as $function$
declare
  request_row public.kuri_join_requests%rowtype;
  actor_id uuid := (select auth.uid());
begin
  if actor_id is null then raise exception 'You must be signed in.'; end if;

  select * into request_row from public.kuri_join_requests r
  where r.id=target_request_id for update;

  if not found then raise exception 'Join request not found.'; end if;

  if not public.has_kuri_admin_role(
    request_row.kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have Kuri administration permission.';
  end if;

  if request_row.status <> 'PENDING' then
    raise exception 'Only pending join requests can be rejected.';
  end if;

  if nullif(trim(rejection_reason_text),'') is null then
    raise exception 'A rejection reason is required.';
  end if;

  update public.kuri_join_requests
  set status='REJECTED',reviewed_by=actor_id,reviewed_at=now(),
      rejection_reason=trim(rejection_reason_text)
  where id=target_request_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select
    k.organization_id,actor_id,'JOIN_REQUEST_REJECTED','KURI_JOIN_REQUEST',request_row.id,
    jsonb_build_object(
      'status','REJECTED',
      'reason',trim(rejection_reason_text)
    ),
    'Join request rejected'
  from public.kuris k where k.id=request_row.kuri_id;
end;
$function$;

revoke all on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) from public,anon;
grant execute on function public.create_kuri_invitation_for_admin(uuid,uuid,text,text,timestamptz) to authenticated;
revoke all on function public.revoke_kuri_invitation_for_admin(uuid) from public,anon;
grant execute on function public.revoke_kuri_invitation_for_admin(uuid) to authenticated;
revoke all on function public.accept_kuri_invitation(text) from public,anon;
grant execute on function public.accept_kuri_invitation(text) to authenticated;
revoke all on function public.list_kuri_join_requests_for_admin(uuid) from public,anon;
grant execute on function public.list_kuri_join_requests_for_admin(uuid) to authenticated;
revoke all on function public.list_kuri_invitations_for_admin(uuid) from public,anon;
grant execute on function public.list_kuri_invitations_for_admin(uuid) to authenticated;
revoke all on function public.approve_kuri_join_request_for_admin(uuid,text) from public,anon;
grant execute on function public.approve_kuri_join_request_for_admin(uuid,text) to authenticated;
revoke all on function public.reject_kuri_join_request_for_admin(uuid,text) from public,anon;
grant execute on function public.reject_kuri_join_request_for_admin(uuid,text) to authenticated;

commit;