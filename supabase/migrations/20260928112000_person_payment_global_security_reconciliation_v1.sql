-- Security reconciliation batch: person creation abuse protection + global input validation.
-- Ported/adapted from main-side 20260927094000 and 20260927095000.
-- Existing pre-reconciliation definitions are preserved in docs/backend/reconciliation-backups/.

begin;

-- ABUSE-005: organization-scoped person creation rate limits.
alter table public.system_capacity_limits
  add column if not exists person_creations_per_10_minutes integer not null default 20
    check (person_creations_per_10_minutes > 0),
  add column if not exists person_creations_per_hour integer not null default 100
    check (person_creations_per_hour > 0);

create table if not exists public.organization_person_creation_rate_limits (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_user_id uuid not null references public.users(id) on delete cascade,
  window_10m_started_at timestamptz not null default now(),
  window_10m_count integer not null default 0 check (window_10m_count >= 0),
  window_hour_started_at timestamptz not null default now(),
  window_hour_count integer not null default 0 check (window_hour_count >= 0),
  updated_at timestamptz not null default now(),
  primary key (organization_id, actor_user_id)
);

alter table public.organization_person_creation_rate_limits enable row level security;

create or replace function public.enforce_person_creation_rate_limit(target_org_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_now timestamptz := now();
  v_max_10m integer;
  v_max_hour integer;
  v_row public.organization_person_creation_rate_limits%rowtype;
  v_10m_count integer;
  v_hour_count integer;
begin
  if v_actor is null then raise exception 'You must be signed in.'; end if;

  select person_creations_per_10_minutes, person_creations_per_hour
    into v_max_10m, v_max_hour
  from public.system_capacity_limits
  where id = true;

  if not found then raise exception 'System capacity configuration is missing'; end if;

  insert into public.organization_person_creation_rate_limits(
    organization_id,actor_user_id,window_10m_started_at,window_10m_count,
    window_hour_started_at,window_hour_count,updated_at
  ) values(target_org_id,v_actor,v_now,0,v_now,0,v_now)
  on conflict (organization_id,actor_user_id) do nothing;

  select * into v_row
  from public.organization_person_creation_rate_limits
  where organization_id=target_org_id and actor_user_id=v_actor
  for update;

  if v_now >= v_row.window_10m_started_at + interval '10 minutes' then
    v_row.window_10m_started_at:=v_now; v_row.window_10m_count:=0;
  end if;
  if v_now >= v_row.window_hour_started_at + interval '1 hour' then
    v_row.window_hour_started_at:=v_now; v_row.window_hour_count:=0;
  end if;

  v_10m_count:=v_row.window_10m_count+1;
  v_hour_count:=v_row.window_hour_count+1;

  if v_10m_count>v_max_10m then raise exception 'Person creation rate limit exceeded. Try again later.'; end if;
  if v_hour_count>v_max_hour then raise exception 'Person creation hourly limit exceeded. Try again later.'; end if;

  update public.organization_person_creation_rate_limits
  set window_10m_started_at=v_row.window_10m_started_at,
      window_10m_count=v_10m_count,
      window_hour_started_at=v_row.window_hour_started_at,
      window_hour_count=v_hour_count,
      updated_at=v_now
  where organization_id=target_org_id and actor_user_id=v_actor;
end;
$function$;

revoke all on function public.enforce_person_creation_rate_limit(uuid) from public,anon,authenticated;

-- GLOBAL-SEC-002: canonical person-name validation.
do $$
begin
  if not exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='is_valid_person_name'
      and pg_get_function_identity_arguments(p.oid)='p_name text'
  ) then
    execute $fn$
      create function public.is_valid_person_name(p_name text)
      returns boolean
      language sql
      immutable
      strict
      set search_path = public
      as $body$
        select
          char_length(btrim(p_name)) between 1 and 200
          and btrim(p_name) = p_name
          and unicode_assigned(normalize(p_name, NFC))
          and p_name !~ '[[:cntrl:]]'
          and p_name ~ '[[:alpha:]]';
      $body$
    $fn$;
  end if;
end
$$;

create or replace function public.is_valid_person_name(p_name text)
returns boolean
language sql
immutable
strict
set search_path = public
as $$
  select
    char_length(btrim(p_name)) between 1 and 200
    and btrim(p_name) = p_name
    and unicode_assigned(normalize(p_name, NFC))
    and p_name !~ '[[:cntrl:]]'
    and p_name ~ '[[:alpha:]]';
$$;

alter function public.is_valid_person_name(text) owner to postgres;
revoke all on function public.is_valid_person_name(text) from public,anon,authenticated;

alter table public.people
  drop constraint if exists people_registered_name_valid,
  drop constraint if exists people_display_name_valid;

alter table public.people
  add constraint people_registered_name_valid
    check (public.is_valid_person_name(registered_name)),
  add constraint people_display_name_valid
    check (display_name is null or public.is_valid_person_name(display_name));

create or replace function public.create_person_for_org_admin(
  target_org_id uuid,
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
set search_path = 'public'
as $function$
declare
  person_id uuid;
  clean_registered_name text := normalize(btrim(registered_name), NFC);
  clean_display_name text := nullif(normalize(btrim(display_name), NFC), '');
  clean_address text := nullif(btrim(address), '');
  clean_notes text := nullif(btrim(notes), '');
  clean_phone text := nullif(btrim(phone), '');
  clean_email text := nullif(btrim(email), '');
begin
  if auth.uid() is null then raise exception 'You must be signed in.'; end if;
  if target_org_id is null then raise exception 'Organization is required.'; end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id=target_org_id
      and ou.user_id=auth.uid()
      and ou.role=any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to add people to this organization.';
  end if;

  if not public.is_valid_person_name(clean_registered_name) then
    raise exception 'Registered name must contain at least one Unicode letter and be between 1 and 200 characters.';
  end if;
  if clean_display_name is not null and not public.is_valid_person_name(clean_display_name) then
    raise exception 'Display name must contain at least one Unicode letter and be between 1 and 200 characters.';
  end if;

  perform public.enforce_person_creation_rate_limit(target_org_id);

  insert into public.people(organization_id,registered_name,display_name,address,notes)
  values(target_org_id,clean_registered_name,clean_display_name,clean_address,clean_notes)
  returning id into person_id;

  if clean_phone is not null then
    insert into public.person_phones(person_id,phone_number,is_primary)
    values(person_id,clean_phone,true);
  end if;
  if clean_email is not null then
    insert into public.person_emails(person_id,email,is_primary)
    values(person_id,clean_email,true);
  end if;

  return person_id;
end;
$function$;

revoke all on function public.create_person_for_org_admin(uuid,text,text,text,text,text,text) from public,anon;
grant execute on function public.create_person_for_org_admin(uuid,text,text,text,text,text,text) to authenticated;

-- GLOBAL-SEC-002: payment-date bounds.
create or replace function public.enforce_payment_date_bounds()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  kuri_start_date date;
begin
  if new.payment_date is null then raise exception 'Payment date is required.'; end if;
  select k.start_date into kuri_start_date from public.kuris k where k.id=new.kuri_id;
  if not found then raise exception 'Kuri not found for payment.'; end if;
  if new.payment_date > now() then raise exception 'Payment date cannot be in the future.'; end if;
  if new.payment_date::date < kuri_start_date then raise exception 'Payment date cannot be before the Kuri start date.'; end if;
  return new;
end;
$function$;

alter function public.enforce_payment_date_bounds() owner to postgres;
revoke all on function public.enforce_payment_date_bounds() from public,anon,authenticated;

drop trigger if exists payments_validate_date_bounds on public.payments;
create trigger payments_validate_date_bounds
before insert or update of kuri_id,payment_date on public.payments
for each row execute function public.enforce_payment_date_bounds();

-- Replace the legacy payment-create RPC with the idempotent contract.
create or replace function public.create_payment_for_admin(
  target_kuri_id uuid,
  target_person_id uuid,
  payment_amount bigint,
  payment_date timestamptz,
  payment_method public.payment_method,
  payment_reference text,
  payment_notes text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $function$
declare
  payment_id uuid;
  target_org_id uuid;
  target_kuri_start_date date;
  v_actor_user_id uuid := auth.uid();
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
begin
  if v_actor_user_id is null then raise exception 'You must be signed in.'; end if;
  if normalized_key is null or char_length(normalized_key)>200 then raise exception 'A valid idempotency key is required.'; end if;
  if payment_amount is null or payment_amount<=0 then raise exception 'Payment amount must be greater than zero.'; end if;
  if payment_date is null then raise exception 'Payment date is required.'; end if;

  request_hash:=encode(extensions.digest(
    jsonb_build_array(target_kuri_id::text,target_person_id::text,payment_amount::text,
      payment_date::text,payment_method::text,coalesce(btrim(payment_reference),''),
      coalesce(btrim(payment_notes),''))::text,'sha256'),'hex');

  insert into public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  values(v_actor_user_id,target_kuri_id,'PAYMENT_CREATE',normalized_key,request_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into idem_row
  from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor_user_id
    and f.operation_type='PAYMENT_CREATE'
    and f.idempotency_key=normalized_key
  for update;

  if idem_row.request_hash<>request_hash then raise exception 'Idempotency key was already used for a different payment request.'; end if;
  if idem_row.status='COMPLETED' then return idem_row.result_payment_id; end if;

  select k.organization_id,k.start_date into target_org_id,target_kuri_start_date
  from public.kuris k where k.id=target_kuri_id;
  if target_org_id is null then raise exception 'Kuri not found.'; end if;
  if payment_date>now() then raise exception 'Payment date cannot be in the future.'; end if;
  if payment_date::date<target_kuri_start_date then raise exception 'Payment date cannot be before the Kuri start date.'; end if;

  if not public.has_kuri_admin_role(target_kuri_id,array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) then
    raise exception 'You do not have permission to record payments for this Kuri.';
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.kuri_id=target_kuri_id
      and coalesce(m.current_holder_person_id,m.person_id)=target_person_id
  ) then raise exception 'Person is not a member of this Kuri.'; end if;

  insert into public.payments(
    kuri_id,organization_id,person_id,amount,payment_date,method,reference_number,status,notes
  ) values(
    target_kuri_id,target_org_id,target_person_id,payment_amount,payment_date,payment_method,
    nullif(btrim(payment_reference),''),'APPROVED',nullif(btrim(payment_notes),'')
  ) returning id into payment_id;

  update public.financial_idempotency_keys
  set status='COMPLETED',result_payment_id=payment_id,completed_at=now()
  where id=idem_row.id;

  return payment_id;
end;
$function$;

-- Do not leave the pre-idempotency 7-argument entrypoint callable.
revoke all on function public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text) from public,anon,authenticated;
revoke all on function public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text) from public,anon;
grant execute on function public.create_payment_for_admin(uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text) to authenticated;

commit;
