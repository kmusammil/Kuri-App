-- SEC-006: creation-volume monitoring for memberships and people.
create or replace function public.audit_person_creation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org_id uuid;
  v_actor uuid := auth.uid();
begin
  v_org_id := new.organization_id;

  if v_org_id is null then
    raise exception 'Unable to resolve organization for person audit event';
  end if;

  insert into public.audit_logs(
    organization_id,user_id,action,entity_type,entity_id,old_data,new_data,reason
  ) values(
    v_org_id,v_actor,'person_created','people',new.id,null,
    jsonb_build_object(
      'id',new.id,
      'organization_id',new.organization_id
    ),
    null
  );

  return new;
end;
$$;

drop trigger if exists audit_person_creation on public.people;
create trigger audit_person_creation
after insert on public.people
for each row execute function public.audit_person_creation();

revoke all on function public.audit_person_creation() from public, anon, authenticated;

create or replace function public.get_creation_volume_monitoring_for_admin(
  target_organization_id uuid,
  window_minutes integer default 60
)
returns table (
  entity_type text,
  user_id uuid,
  creations bigint,
  window_started_at timestamptz,
  alert_level text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_start timestamptz;
  v_membership_hour_limit integer;
  v_membership_10m_limit integer;
begin
  if v_actor is null then
    raise exception 'Authentication required';
  end if;

  if window_minutes < 1 or window_minutes > 1440 then
    raise exception 'window_minutes must be between 1 and 1440';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = target_organization_id
      and ou.user_id = v_actor
      and ou.role in ('MAIN_ADMIN','ADMIN')
  ) then
    raise exception 'Organization admin access required';
  end if;

  select
    scl.membership_creations_per_hour,
    scl.membership_creations_per_10_minutes
  into
    v_membership_hour_limit,
    v_membership_10m_limit
  from public.system_capacity_limits scl
  limit 1;

  v_start := now() - make_interval(mins => window_minutes);

  return query
  select
    al.entity_type,
    al.user_id,
    count(*)::bigint,
    v_start,
    case
      when al.entity_type = 'memberships'
           and count(*) >= greatest(1, floor(v_membership_hour_limit * 0.8)::bigint)
        then 'WARNING'
      when al.entity_type = 'memberships'
           and count(*) >= greatest(1, floor(v_membership_hour_limit * 0.5)::bigint)
        then 'ELEVATED'
      else 'NORMAL'
    end
  from public.audit_logs al
  where al.organization_id = target_organization_id
    and al.created_at >= v_start
    and al.action in ('membership_created','person_created')
  group by al.entity_type, al.user_id
  order by count(*) desc;
end;
$$;

revoke all on function public.get_creation_volume_monitoring_for_admin(uuid,integer) from public, anon;
grant execute on function public.get_creation_volume_monitoring_for_admin(uuid,integer) to authenticated;