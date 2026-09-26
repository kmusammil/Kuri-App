begin;

alter table public.kuris
  add column if not exists discoverable boolean not null default true;

create or replace function public.set_kuri_discoverability(
  target_kuri_id uuid,
  target_discoverable boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  caller uuid := (select auth.uid());
begin
  if caller is null then
    raise exception 'You must be signed in.';
  end if;

  if target_kuri_id is null then
    raise exception 'Kuri is required.';
  end if;

  if target_discoverable is null then
    raise exception 'Discoverability value is required.';
  end if;

  if not exists (
    select 1
    from public.kuri_admins ka
    where ka.kuri_id = target_kuri_id
      and ka.user_id = caller
      and ka.role in ('MAIN_ADMIN','ADMIN')
  ) then
    raise exception 'You do not have permission to change Kuri discoverability.';
  end if;

  update public.kuris
     set discoverable = target_discoverable,
         updated_at = now()
   where id = target_kuri_id;

  if not found then
    raise exception 'Kuri not found.';
  end if;

  insert into public.audit_logs(
    event_type, actor_user_id, organization_id, kuri_id, metadata
  )
  select
    'KURI_DISCOVERABILITY_UPDATED',
    caller,
    k.organization_id,
    k.id,
    jsonb_build_object('discoverable', target_discoverable)
  from public.kuris k
  where k.id = target_kuri_id;
end;
$function$;

create or replace function public.search_discoverable_kuris(
  search_query text default null
)
returns table(
  id uuid,
  name text,
  description text,
  organization_id uuid,
  status public.kuri_status,
  start_date date,
  membership_limit integer
)
language sql
security definer
set search_path = ''
as $function$
  select k.id,
         k.name,
         k.description,
         k.organization_id,
         k.status,
         k.start_date,
         k.membership_limit
  from public.kuris k
  where k.discoverable = true
    and k.status in ('DRAFT','OPEN','ACTIVE')
    and (
      nullif(trim(search_query), '') is null
      or k.name ilike '%' || trim(search_query) || '%'
      or coalesce(k.description, '') ilike '%' || trim(search_query) || '%'
    )
  order by k.name, k.id;
$function$;

create or replace function public.request_to_join_kuri(
  target_kuri_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  actor_id uuid := (select auth.uid());
  applicant_person_id uuid;
  target_organization_id uuid;
  target_discoverable boolean;
  request_id uuid;
  current_window_started_at timestamptz;
  current_request_count integer;
begin
  if actor_id is null then raise exception 'You must be signed in.'; end if;

  select u.person_id into applicant_person_id
  from public.users u where u.id=actor_id;

  if applicant_person_id is null then
    raise exception 'Complete your account profile before joining a Kuri.';
  end if;

  select k.organization_id,k.discoverable
    into target_organization_id,target_discoverable
  from public.kuris k
  where k.id=target_kuri_id
    and k.status in ('OPEN','ACTIVE')
    and k.join_policy='REQUEST_APPROVAL'
  for update;

  if not found then
    raise exception 'This Kuri does not accept self-service join requests.';
  end if;

  if not target_discoverable then
    raise exception 'This Kuri is not discoverable. Join using a valid invitation link or code.';
  end if;

  if not exists (
    select 1 from public.people p
    where p.id=applicant_person_id
      and p.organization_id=target_organization_id
  ) then
    raise exception 'You are not eligible to join this Kuri.';
  end if;

  if exists (
    select 1 from public.memberships m
    where m.kuri_id=target_kuri_id
      and m.person_id=applicant_person_id
      and m.status<>'EXITED'
  ) then
    raise exception 'You already have a membership in this Kuri.';
  end if;

  if exists (
    select 1 from public.kuri_join_requests r
    where r.kuri_id=target_kuri_id
      and r.applicant_user_id=actor_id
      and r.status='PENDING'
  ) then
    raise exception 'You already have a pending join request for this Kuri.';
  end if;

  insert into public.kuri_join_request_rate_limits(user_id)
  values(actor_id)
  on conflict (user_id) do nothing;

  select window_started_at,request_count
    into current_window_started_at,current_request_count
  from public.kuri_join_request_rate_limits
  where user_id=actor_id
  for update;

  if current_window_started_at <= now()-interval '1 hour' then
    update public.kuri_join_request_rate_limits
    set window_started_at=now(),request_count=0,updated_at=now()
    where user_id=actor_id;
    current_request_count:=0;
  end if;

  if current_request_count>=10 then
    raise exception 'Join request rate limit exceeded. Please try again later.';
  end if;

  update public.kuri_join_request_rate_limits
  set request_count=request_count+1,updated_at=now()
  where user_id=actor_id;

  insert into public.kuri_join_requests(
    kuri_id,applicant_user_id,applicant_person_id
  )
  values(target_kuri_id,actor_id,applicant_person_id)
  returning id into request_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  values(
    target_organization_id,actor_id,'JOIN_REQUEST_CREATED','KURI_JOIN_REQUEST',request_id,
    jsonb_build_object(
      'kuri_id',target_kuri_id,
      'applicant_person_id',applicant_person_id,
      'join_policy','REQUEST_APPROVAL'
    ),
    'Self-service Kuri join request submitted.'
  );

  return request_id;
end;
$function$;

revoke execute on function public.set_kuri_discoverability(uuid,boolean) from public, anon;
grant execute on function public.set_kuri_discoverability(uuid,boolean) to authenticated;
revoke execute on function public.search_discoverable_kuris(text) from public, anon;
grant execute on function public.search_discoverable_kuris(text) to authenticated;
revoke execute on function public.request_to_join_kuri(uuid) from public, anon;
grant execute on function public.request_to_join_kuri(uuid) to authenticated;

commit;