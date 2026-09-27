begin;

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
revoke all on function public.is_valid_person_name(text) from public, anon, authenticated;

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
set search_path = public
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
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if target_org_id is null then
    raise exception 'Organization is required.';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = target_org_id
      and ou.user_id = auth.uid()
      and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
  ) then
    raise exception 'You do not have permission to add people to this organization.';
  end if;

  if not public.is_valid_person_name(clean_registered_name) then
    raise exception 'Registered name must contain at least one Unicode letter and be between 1 and 200 characters.';
  end if;

  if clean_display_name is not null
     and not public.is_valid_person_name(clean_display_name) then
    raise exception 'Display name must contain at least one Unicode letter and be between 1 and 200 characters.';
  end if;

  insert into public.people (
    organization_id,
    registered_name,
    display_name,
    address,
    notes
  )
  values (
    target_org_id,
    clean_registered_name,
    clean_display_name,
    clean_address,
    clean_notes
  )
  returning id into person_id;

  if clean_phone is not null then
    insert into public.person_phones (person_id, phone_number, is_primary)
    values (person_id, clean_phone, true);
  end if;

  if clean_email is not null then
    insert into public.person_emails (person_id, email, is_primary)
    values (person_id, clean_email, true);
  end if;

  return person_id;
end;
$function$;

create or replace function public.enforce_payment_date_bounds()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  kuri_start_date date;
begin
  if new.payment_date is null then
    raise exception 'Payment date is required.';
  end if;

  select k.start_date
    into kuri_start_date
  from public.kuris k
  where k.id = new.kuri_id;

  if not found then
    raise exception 'Kuri not found for payment.';
  end if;

  if new.payment_date > now() then
    raise exception 'Payment date cannot be in the future.';
  end if;

  if new.payment_date::date < kuri_start_date then
    raise exception 'Payment date cannot be before the Kuri start date.';
  end if;

  return new;
end;
$function$;

alter function public.enforce_payment_date_bounds() owner to postgres;
revoke all on function public.enforce_payment_date_bounds() from public, anon, authenticated;

drop trigger if exists payments_validate_date_bounds on public.payments;
create trigger payments_validate_date_bounds
before insert or update of kuri_id, payment_date
on public.payments
for each row
execute function public.enforce_payment_date_bounds();

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
  v_actor_user_id uuid := (select auth.uid());
  normalized_key text := nullif(btrim(p_idempotency_key),'');
  request_hash text;
  idem_row public.financial_idempotency_keys%rowtype;
begin
  if v_actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if normalized_key is null or char_length(normalized_key)>200 then
    raise exception 'A valid idempotency key is required.';
  end if;

  if payment_amount is null or payment_amount<=0 then
    raise exception 'Payment amount must be greater than zero.';
  end if;

  if payment_date is null then
    raise exception 'Payment date is required.';
  end if;

  request_hash := encode(extensions.digest(
    jsonb_build_array(
      target_kuri_id::text,target_person_id::text,payment_amount::text,
      payment_date::text,payment_method::text,
      coalesce(btrim(payment_reference),''),
      coalesce(btrim(payment_notes),'')
    )::text,'sha256'),'hex');

  insert into public.financial_idempotency_keys(
    actor_user_id,kuri_id,operation_type,idempotency_key,request_hash
  )
  values(v_actor_user_id,target_kuri_id,'PAYMENT_CREATE',normalized_key,request_hash)
  on conflict(actor_user_id,operation_type,idempotency_key) do nothing;

  select f.* into idem_row
  from public.financial_idempotency_keys f
  where f.actor_user_id=v_actor_user_id
    and f.operation_type='PAYMENT_CREATE'
    and f.idempotency_key=normalized_key
  for update;

  if idem_row.request_hash<>request_hash then
    raise exception 'Idempotency key was already used for a different payment request.';
  end if;

  if idem_row.status='COMPLETED' then
    return idem_row.result_payment_id;
  end if;

  select k.organization_id,k.start_date
    into target_org_id,target_kuri_start_date
  from public.kuris k
  where k.id=target_kuri_id;

  if target_org_id is null then
    raise exception 'Kuri not found.';
  end if;

  if payment_date > now() then
    raise exception 'Payment date cannot be in the future.';
  end if;

  if payment_date::date < target_kuri_start_date then
    raise exception 'Payment date cannot be before the Kuri start date.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to record payments for this Kuri.';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.kuri_id=target_kuri_id
      and coalesce(m.current_holder_person_id,m.person_id)=target_person_id
  ) then
    raise exception 'Person is not a member of this Kuri.';
  end if;

  insert into public.payments(
    kuri_id,organization_id,person_id,amount,payment_date,method,
    reference_number,status,notes
  )
  values(
    target_kuri_id,target_org_id,target_person_id,payment_amount,payment_date,
    payment_method,nullif(btrim(payment_reference),''),
    'APPROVED',nullif(btrim(payment_notes),'')
  )
  returning id into payment_id;

  update public.financial_idempotency_keys
  set status='COMPLETED',result_payment_id=payment_id,completed_at=now()
  where id=idem_row.id;

  return payment_id;
end
$function$;

revoke all on function public.create_payment_for_admin(
  uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text
) from public, anon;
grant execute on function public.create_payment_for_admin(
  uuid,uuid,bigint,timestamptz,public.payment_method,text,text,text
) to authenticated;

commit;
