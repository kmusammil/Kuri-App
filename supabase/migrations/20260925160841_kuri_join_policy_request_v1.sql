begin;

alter table public.kuris
  add column if not exists join_policy text not null default 'INVITE_ONLY';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'kuris_join_policy_check'
      and conrelid = 'public.kuris'::regclass
  ) then
    alter table public.kuris
      add constraint kuris_join_policy_check
      check (join_policy in ('INVITE_ONLY','REQUEST_APPROVAL'));
  end if;
end;
$$;

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
  request_id uuid;
begin
  if actor_id is null then raise exception 'You must be signed in.'; end if;

  select u.person_id
    into applicant_person_id
  from public.users u
  where u.id=actor_id;

  if applicant_person_id is null then
    raise exception 'Complete your account profile before joining a Kuri.';
  end if;

  select k.organization_id
    into target_organization_id
  from public.kuris k
  where k.id=target_kuri_id
    and k.status in ('OPEN','ACTIVE')
    and k.join_policy='REQUEST_APPROVAL'
  for update;

  if not found then
    raise exception 'This Kuri does not accept self-service join requests.';
  end if;

  if not exists (
    select 1
    from public.people p
    where p.id=applicant_person_id
      and p.organization_id=target_organization_id
  ) then
    raise exception 'You are not eligible to join this Kuri.';
  end if;

  if exists (
    select 1
    from public.memberships m
    where m.kuri_id=target_kuri_id
      and m.person_id=applicant_person_id
      and m.status<>'EXITED'
  ) then
    raise exception 'You already have a membership in this Kuri.';
  end if;

  if exists (
    select 1
    from public.kuri_join_requests r
    where r.kuri_id=target_kuri_id
      and r.applicant_user_id=actor_id
      and r.status='PENDING'
  ) then
    raise exception 'You already have a pending join request for this Kuri.';
  end if;

  insert into public.kuri_join_requests(
    kuri_id,applicant_user_id,applicant_person_id
  )
  values(target_kuri_id,actor_id,applicant_person_id)
  returning id into request_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  values(
    target_organization_id,
    actor_id,
    'JOIN_REQUEST_CREATED',
    'KURI_JOIN_REQUEST',
    request_id,
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

revoke execute on function public.request_to_join_kuri(uuid) from public, anon;
grant execute on function public.request_to_join_kuri(uuid) to authenticated;

commit;