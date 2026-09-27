begin;

create table if not exists public.person_claim_tokens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  issued_by_user_id uuid not null references public.users(id) on delete restrict,
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by_user_id uuid references public.users(id) on delete restrict,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check (expires_at > created_at)
);

create index if not exists person_claim_tokens_person_idx
  on public.person_claim_tokens(person_id, created_at desc);

create index if not exists person_claim_tokens_active_idx
  on public.person_claim_tokens(person_id, expires_at)
  where used_at is null and revoked_at is null;

alter table public.person_claim_tokens enable row level security;

revoke all on table public.person_claim_tokens from public, anon, authenticated;

create unique index if not exists users_person_id_unique
  on public.users(person_id)
  where person_id is not null;

create or replace function public.create_person_claim_token_for_admin(
  target_person_id uuid,
  expires_in_hours integer default 72
)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_org_id uuid;
  v_token text;
  v_hash text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required.';
  end if;

  if expires_in_hours < 1 or expires_in_hours > 168 then
    raise exception 'Claim token expiry must be between 1 and 168 hours.';
  end if;

  select p.organization_id
    into v_org_id
  from public.people p
  where p.id = target_person_id
  for update;

  if v_org_id is null then
    raise exception 'Person not found.';
  end if;

  if not public.has_org_role(
    v_org_id,
    array['MAIN_ADMIN','ADMIN']::public.app_role[]
  ) then
    raise exception 'You do not have permission to issue a claim token for this person.';
  end if;

  if exists (
    select 1
    from public.users u
    where u.person_id = target_person_id
  ) then
    raise exception 'This person is already linked to a user account.';
  end if;

  v_token :=
    lower(encode(gen_random_bytes(24), 'hex'));

  v_hash :=
    encode(digest(v_token, 'sha256'), 'hex');

  insert into public.person_claim_tokens (
    organization_id,
    person_id,
    issued_by_user_id,
    token_hash,
    expires_at
  )
  values (
    v_org_id,
    target_person_id,
    auth.uid(),
    v_hash,
    now() + make_interval(hours => expires_in_hours)
  );

  insert into public.audit_logs (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    new_data,
    reason
  )
  values (
    v_org_id,
    auth.uid(),
    'person_claim_token_created',
    'person',
    target_person_id,
    jsonb_build_object(
      'expires_in_hours', expires_in_hours
    ),
    'Issued one-time person claim token'
  );

  return v_token;
end;
$function$;

create or replace function public.claim_existing_person(
  claim_token text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
  v_token_id uuid;
  v_person_id uuid;
  v_org_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required.';
  end if;

  claim_token := lower(trim(claim_token));

  if length(claim_token) <> 48
     or claim_token !~ '^[0-9a-f]{48}$' then
    raise exception 'Invalid claim token.';
  end if;

  select u.person_id
    into v_person_id
  from public.users u
  where u.id = v_user_id
  for update;

  if not found then
    raise exception 'User account not found.';
  end if;

  if v_person_id is not null then
    raise exception 'This user account is already linked to a person.';
  end if;

  select
    pct.id,
    pct.person_id,
    pct.organization_id
    into v_token_id, v_person_id, v_org_id
  from public.person_claim_tokens pct
  where pct.token_hash = encode(digest(claim_token, 'sha256'), 'hex')
    and pct.used_at is null
    and pct.revoked_at is null
    and pct.expires_at > now()
  for update;

  if not found then
    raise exception 'Invalid, expired, revoked, or already-used claim token.';
  end if;

  if exists (
    select 1
    from public.users u
    where u.person_id = v_person_id
      and u.id <> v_user_id
  ) then
    raise exception 'This person is already linked to another user account.';
  end if;

  update public.users
  set person_id = v_person_id
  where id = v_user_id
    and person_id is null;

  if not found then
    raise exception 'Unable to claim this person.';
  end if;

  update public.person_claim_tokens
  set used_at = now(),
      used_by_user_id = v_user_id
  where id = v_token_id
    and used_at is null
    and revoked_at is null;

  if not found then
    raise exception 'Claim token was already consumed.';
  end if;

  insert into public.audit_logs (
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    new_data,
    reason
  )
  values (
    v_org_id,
    v_user_id,
    'person_claimed',
    'person',
    v_person_id,
    jsonb_build_object(
      'claim_token_id', v_token_id
    ),
    'Authenticated user claimed existing person identity'
  );

  return v_person_id;
end;
$function$;

revoke all on function public.create_person_claim_token_for_admin(uuid, integer) from public, anon;
grant execute on function public.create_person_claim_token_for_admin(uuid, integer) to authenticated;

revoke all on function public.claim_existing_person(text) from public, anon;
grant execute on function public.claim_existing_person(text) to authenticated;

commit;