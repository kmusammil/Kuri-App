begin;

-- Admin-only RPC for reading one global person and their contact details.
create or replace function public.get_person_for_admin(target_person_id uuid)
returns table (
  id uuid,
  registered_name text,
  display_name text,
  address text,
  notes text,
  created_at timestamptz,
  phones jsonb,
  emails jsonb
)
language sql
security definer
set search_path = public
stable
as $$
  select
    p.id,
    p.registered_name,
    p.display_name,
    p.address,
    p.notes,
    p.created_at,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', pp.id,
            'phone_number', pp.phone_number,
            'label', pp.label,
            'is_primary', pp.is_primary
          ) order by pp.is_primary desc, pp.id
        )
        from public.person_phones pp
        where pp.person_id = p.id
      ),
      '[]'::jsonb
    ) as phones,
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'id', pe.id,
            'email', pe.email,
            'label', pe.label,
            'is_primary', pe.is_primary
          ) order by pe.is_primary desc, pe.id
        )
        from public.person_emails pe
        where pe.person_id = p.id
      ),
      '[]'::jsonb
    ) as emails
  from public.people p
  where p.id = target_person_id
    and exists (
      select 1
      from public.organization_users ou
      where ou.user_id = auth.uid()
        and ou.role = any(array['MAIN_ADMIN','ADMIN']::public.app_role[])
    );
$$;

revoke all on function public.get_person_for_admin(uuid) from public;
grant execute on function public.get_person_for_admin(uuid) to authenticated;

grant usage on schema public to authenticated;

commit;
