begin;

do $$
begin
  create type public.kuri_announcement_status as enum (
    'DRAFT',
    'SCHEDULED',
    'PUBLISHED',
    'WITHDRAWN',
    'EXPIRED'
  );
exception when duplicate_object then null;
end;
$$;

create table public.kuri_announcements (
  id uuid primary key default gen_random_uuid(),
  kuri_id uuid not null references public.kuris(id) on delete restrict,
  author_user_id uuid not null references public.users(id) on delete restrict,
  title text not null,
  body text not null,
  status public.kuri_announcement_status not null default 'DRAFT',
  audience jsonb not null default '{"type":"KURI_FULL_AUDIENCE"}'::jsonb,
  version integer not null default 1,
  scheduled_at timestamptz,
  published_at timestamptz,
  withdrawn_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint kuri_announcements_title_check
    check (char_length(btrim(title)) between 1 and 200),
  constraint kuri_announcements_body_check
    check (char_length(btrim(body)) between 1 and 10000),
  constraint kuri_announcements_version_check
    check (version >= 1),
  constraint kuri_announcements_audience_check
    check (
      jsonb_typeof(audience) = 'object'
      and audience->>'type' = 'KURI_FULL_AUDIENCE'
    ),
  constraint kuri_announcements_status_dates_check
    check (
      (status = 'DRAFT' and published_at is null and withdrawn_at is null)
      or
      (status = 'SCHEDULED' and scheduled_at is not null and published_at is null and withdrawn_at is null)
      or
      (status = 'PUBLISHED' and published_at is not null and withdrawn_at is null)
      or
      (status = 'WITHDRAWN' and withdrawn_at is not null)
      or
      (status = 'EXPIRED' and expires_at is not null)
    ),
  constraint kuri_announcements_expiry_check
    check (expires_at is null or scheduled_at is null or expires_at > scheduled_at),
  constraint kuri_announcements_published_expiry_check
    check (expires_at is null or published_at is null or expires_at > published_at)
);

create index kuri_announcements_kuri_status_idx
  on public.kuri_announcements(kuri_id,status,updated_at desc);

create index kuri_announcements_kuri_published_idx
  on public.kuri_announcements(kuri_id,published_at desc)
  where status = 'PUBLISHED';

create index kuri_announcements_scheduled_idx
  on public.kuri_announcements(scheduled_at)
  where status = 'SCHEDULED';

create table public.kuri_announcement_versions (
  id uuid primary key default gen_random_uuid(),
  announcement_id uuid not null references public.kuri_announcements(id) on delete cascade,
  version integer not null,
  title text not null,
  body text not null,
  audience jsonb not null,
  scheduled_at timestamptz,
  expires_at timestamptz,
  changed_by uuid references public.users(id) on delete set null,
  changed_at timestamptz not null default now(),
  constraint kuri_announcement_versions_unique
    unique (announcement_id,version),
  constraint kuri_announcement_versions_title_check
    check (char_length(btrim(title)) between 1 and 200),
  constraint kuri_announcement_versions_body_check
    check (char_length(btrim(body)) between 1 and 10000),
  constraint kuri_announcement_versions_audience_check
    check (
      jsonb_typeof(audience) = 'object'
      and audience->>'type' = 'KURI_FULL_AUDIENCE'
    )
);

create index kuri_announcement_versions_announcement_idx
  on public.kuri_announcement_versions(announcement_id,version desc);

alter table public.kuri_announcements enable row level security;
alter table public.kuri_announcement_versions enable row level security;

revoke all on table public.kuri_announcements from public,anon,authenticated;
revoke all on table public.kuri_announcement_versions from public,anon,authenticated;

grant select on public.kuri_announcements to authenticated;

create policy kuri_announcements_select
on public.kuri_announcements
for select
to authenticated
using (
  exists (
    select 1
    from public.kuris k
    where k.id = kuri_announcements.kuri_id
      and (
        public.has_kuri_admin_role(
          k.id,
          array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
        )
        or (
          public.is_org_member(k.organization_id)
          and kuri_announcements.status = 'PUBLISHED'
          and (kuri_announcements.expires_at is null or kuri_announcements.expires_at > now())
        )
      )
  )
);

create or replace function public.create_kuri_announcement_for_admin(
  target_kuri_id uuid,
  title_text text,
  body_text text,
  expires_at_value timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  announcement_id uuid;
begin
  if actor_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if not public.has_kuri_admin_role(
    target_kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to create an announcement for this Kuri.';
  end if;

  if nullif(btrim(title_text),'') is null
     or char_length(btrim(title_text)) > 200
     or nullif(btrim(body_text),'') is null
     or char_length(btrim(body_text)) > 10000 then
    raise exception 'Announcement title/body is invalid.';
  end if;

  if expires_at_value is not null and expires_at_value <= now() then
    raise exception 'Announcement expiry must be in the future.';
  end if;

  insert into public.kuri_announcements(
    kuri_id,author_user_id,title,body,expires_at
  )
  values(
    target_kuri_id,actor_user_id,btrim(title_text),btrim(body_text),expires_at_value
  )
  returning id into announcement_id;

  insert into public.kuri_announcement_versions(
    announcement_id,version,title,body,audience,scheduled_at,expires_at,changed_by
  )
  select id,version,title,body,audience,scheduled_at,expires_at,actor_user_id
  from public.kuri_announcements
  where id=announcement_id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_CREATED',
    'kuri_announcement',a.id,
    jsonb_build_object(
      'kuri_id',a.kuri_id,
      'status',a.status::text,
      'version',a.version,
      'title',a.title,
      'expires_at',a.expires_at
    ),
    'Kuri announcement created.'
  from public.kuri_announcements a
  join public.kuris k on k.id=a.kuri_id
  where a.id=announcement_id;

  return announcement_id;
end;
$function$;

create or replace function public.update_kuri_announcement_for_admin(
  target_announcement_id uuid,
  title_text text,
  body_text text,
  expires_at_value timestamptz default null,
  scheduled_at_value timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  a public.kuri_announcements%rowtype;
  next_version integer;
begin
  select *
    into a
  from public.kuri_announcements
  where id=target_announcement_id
  for update;

  if not found then
    raise exception 'Announcement not found.';
  end if;

  if not public.has_kuri_admin_role(
    a.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to edit this announcement.';
  end if;

  if a.status not in ('DRAFT','SCHEDULED') then
    raise exception 'Only draft or scheduled announcements can be edited.';
  end if;

  if nullif(btrim(title_text),'') is null
     or char_length(btrim(title_text)) > 200
     or nullif(btrim(body_text),'') is null
     or char_length(btrim(body_text)) > 10000 then
    raise exception 'Announcement title/body is invalid.';
  end if;

  if scheduled_at_value is not null and scheduled_at_value <= now() then
    raise exception 'Scheduled publication must be in the future.';
  end if;

  if expires_at_value is not null
     and coalesce(scheduled_at_value, a.scheduled_at, now()) >= expires_at_value then
    raise exception 'Announcement expiry must be after publication time.';
  end if;

  next_version := a.version + 1;

  update public.kuri_announcements
  set title=btrim(title_text),
      body=btrim(body_text),
      expires_at=expires_at_value,
      scheduled_at=case
        when scheduled_at_value is null then null
        else scheduled_at_value
      end,
      status=case
        when scheduled_at_value is null then 'DRAFT'::public.kuri_announcement_status
        else 'SCHEDULED'::public.kuri_announcement_status
      end,
      version=next_version,
      updated_at=now()
  where id=a.id;

  insert into public.kuri_announcement_versions(
    announcement_id,version,title,body,audience,scheduled_at,expires_at,changed_by
  )
  values(
    a.id,next_version,btrim(title_text),btrim(body_text),
    a.audience,scheduled_at_value,expires_at_value,actor_user_id
  );

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_EDITED',
    'kuri_announcement',a.id,
    jsonb_build_object(
      'status',a.status::text,
      'version',a.version,
      'title',a.title,
      'body',a.body,
      'scheduled_at',a.scheduled_at,
      'expires_at',a.expires_at
    ),
    jsonb_build_object(
      'status',case when scheduled_at_value is null then 'DRAFT' else 'SCHEDULED' end,
      'version',next_version,
      'title',btrim(title_text),
      'body',btrim(body_text),
      'scheduled_at',scheduled_at_value,
      'expires_at',expires_at_value
    ),
    'Kuri announcement edited.'
  from public.kuris k
  where k.id=a.kuri_id;

  return next_version;
end;
$function$;

create or replace function public.publish_kuri_announcement_for_admin(
  target_announcement_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  a public.kuri_announcements%rowtype;
begin
  select * into a
  from public.kuri_announcements
  where id=target_announcement_id
  for update;

  if not found then
    raise exception 'Announcement not found.';
  end if;

  if not public.has_kuri_admin_role(
    a.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to publish this announcement.';
  end if;

  if a.status not in ('DRAFT','SCHEDULED') then
    raise exception 'Only draft or scheduled announcements can be published.';
  end if;

  if a.expires_at is not null and a.expires_at <= now() then
    raise exception 'Announcement expiry has already passed.';
  end if;

  update public.kuri_announcements
  set status='PUBLISHED',
      scheduled_at=null,
      published_at=coalesce(published_at,now()),
      updated_at=now()
  where id=a.id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_PUBLISHED',
    'kuri_announcement',a.id,
    jsonb_build_object('status',a.status::text,'version',a.version),
    jsonb_build_object('status','PUBLISHED','version',a.version),
    'Kuri announcement published.'
  from public.kuris k
  where k.id=a.kuri_id;

  return a.id;
end;
$function$;

create or replace function public.withdraw_kuri_announcement_for_admin(
  target_announcement_id uuid
)
returns uuid
language plpgsql
security definer
set search_path=public
as $function$
declare
  actor_user_id uuid := (select auth.uid());
  a public.kuri_announcements%rowtype;
begin
  select * into a
  from public.kuri_announcements
  where id=target_announcement_id
  for update;

  if not found then
    raise exception 'Announcement not found.';
  end if;

  if not public.has_kuri_admin_role(
    a.kuri_id,
    array['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
  ) then
    raise exception 'You do not have permission to withdraw this announcement.';
  end if;

  if a.status not in ('PUBLISHED','SCHEDULED') then
    raise exception 'Only published or scheduled announcements can be withdrawn.';
  end if;

  update public.kuri_announcements
  set status='WITHDRAWN',
      withdrawn_at=now(),
      scheduled_at=null,
      updated_at=now()
  where id=a.id;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  )
  select
    k.organization_id,actor_user_id,'KURI_ANNOUNCEMENT_WITHDRAWN',
    'kuri_announcement',a.id,
    jsonb_build_object('status',a.status::text,'version',a.version),
    jsonb_build_object('status','WITHDRAWN','version',a.version),
    'Kuri announcement withdrawn.'
  from public.kuris k
  where k.id=a.kuri_id;

  return a.id;
end;
$function$;

create or replace function public.process_kuri_announcements()
returns integer
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_changed integer := 0;
  v_rows integer;
begin
  update public.kuri_announcements
  set status=case
      when expires_at is not null and expires_at <= now()
        then 'EXPIRED'::public.kuri_announcement_status
      else 'PUBLISHED'::public.kuri_announcement_status
    end,
    published_at=case
      when expires_at is not null and expires_at <= now()
        then published_at
      else coalesce(published_at,now())
    end,
    scheduled_at=null,
    updated_at=now()
  where status='SCHEDULED'
    and scheduled_at <= now();
  get diagnostics v_rows=row_count;
  v_changed:=v_changed+v_rows;

  update public.kuri_announcements
  set status='EXPIRED',
      updated_at=now()
  where status='PUBLISHED'
    and expires_at is not null
    and expires_at <= now();
  get diagnostics v_rows=row_count;
  v_changed:=v_changed+v_rows;

  return v_changed;
end;
$function$;

create or replace function public.emit_kuri_announcement_notification_event()
returns trigger
language plpgsql
security definer
set search_path=public
as $function$
declare
  v_org_id uuid;
begin
  if new.status='PUBLISHED'
     and (tg_op='INSERT' or old.status is distinct from new.status) then
    select organization_id into v_org_id
    from public.kuris
    where id=new.kuri_id;

    perform public.emit_notification_event_internal(
      new.kuri_id,
      'KURI_ANNOUNCEMENT',
      'kuri_announcement',
      new.id,
      jsonb_build_object(
        'announcement_id',new.id,
        'kuri_id',new.kuri_id,
        'author_user_id',new.author_user_id,
        'title',new.title,
        'body',new.body,
        'version',new.version,
        'audience',new.audience,
        'published_at',new.published_at,
        'expires_at',new.expires_at
      ),
      'kuri-announcement:'||new.id::text||':published:'||new.version::text,
      new.author_user_id
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists emit_kuri_announcement_notification_event
  on public.kuri_announcements;

create trigger emit_kuri_announcement_notification_event
after insert or update of status on public.kuri_announcements
for each row
execute function public.emit_kuri_announcement_notification_event();

revoke all on function public.create_kuri_announcement_for_admin(uuid,text,text,timestamptz)
  from public,anon,authenticated;
grant execute on function public.create_kuri_announcement_for_admin(uuid,text,text,timestamptz)
  to authenticated;

revoke all on function public.update_kuri_announcement_for_admin(uuid,text,text,timestamptz,timestamptz)
  from public,anon,authenticated;
grant execute on function public.update_kuri_announcement_for_admin(uuid,text,text,timestamptz,timestamptz)
  to authenticated;

revoke all on function public.publish_kuri_announcement_for_admin(uuid)
  from public,anon,authenticated;
grant execute on function public.publish_kuri_announcement_for_admin(uuid)
  to authenticated;

revoke all on function public.withdraw_kuri_announcement_for_admin(uuid)
  from public,anon,authenticated;
grant execute on function public.withdraw_kuri_announcement_for_admin(uuid)
  to authenticated;

revoke all on function public.process_kuri_announcements()
  from public,anon,authenticated;

revoke all on function public.emit_kuri_announcement_notification_event()
  from public,anon,authenticated;

select cron.schedule(
  'kuri-announcement-state-processor',
  '* * * * *',
  $$select public.process_kuri_announcements();$$
)
where not exists (
  select 1 from cron.job where jobname='kuri-announcement-state-processor'
);

commit;