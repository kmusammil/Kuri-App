begin;

-- Legacy authority recovery for existing Kuris created before Kuri-level
-- authority was introduced. Do not guess when organization authority is
-- ambiguous: require exactly one MAIN_ADMIN, or exactly one admin-capable user.
do $$
declare
  r record;
  main_count integer;
  admin_capable_count integer;
  selected_user uuid;
begin
  for r in
    select k.id, k.organization_id
    from public.kuris k
    order by k.id
  loop
    if exists (
      select 1 from public.kuri_admins ka where ka.kuri_id=r.id
    ) then
      continue;
    end if;

    select count(*), (array_agg(ou.user_id order by ou.user_id))[1]
      into main_count, selected_user
    from public.organization_users ou
    where ou.organization_id=r.organization_id
      and ou.role='MAIN_ADMIN';

    if main_count<>1 then
      select count(*), (array_agg(ou.user_id order by ou.user_id))[1]
        into admin_capable_count, selected_user
      from public.organization_users ou
      where ou.organization_id=r.organization_id
        and ou.role in ('MAIN_ADMIN','ADMIN');

      if admin_capable_count<>1 then
        raise exception
          'Cannot establish legacy Kuri admin for Kuri %. Organization % has neither exactly one MAIN_ADMIN nor exactly one admin-capable user.',
          r.id, r.organization_id;
      end if;
    end if;

    insert into public.kuri_admins(kuri_id,user_id,role)
    values(r.id,selected_user,'MAIN_ADMIN');

    insert into public.audit_logs(
      organization_id,user_id,action,entity_type,entity_id,new_data,reason
    )
    values(
      r.organization_id,selected_user,'KURI_ADMIN_LEGACY_RECOVERY','kuri_admins',r.id,
      jsonb_build_object('role','MAIN_ADMIN','source','sole_current_organization_admin'),
      'Legacy Kuri authority recovery: no Kuri admin record existed after authority foundation migration.'
    );
  end loop;
end $$;

commit;