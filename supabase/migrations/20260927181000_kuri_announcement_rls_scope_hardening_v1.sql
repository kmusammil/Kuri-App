begin;

drop policy if exists kuri_announcements_select on public.kuri_announcements;

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
        or exists (
          select 1
          from public.organization_users ou
          where ou.organization_id = k.organization_id
            and ou.user_id = (select auth.uid())
            and ou.role = 'MAIN_ADMIN'::public.app_role
        )
        or (
          kuri_announcements.status = 'PUBLISHED'
          and (kuri_announcements.expires_at is null or kuri_announcements.expires_at > now())
          and exists (
            select 1
            from public.memberships m
            join public.users u on u.person_id = m.person_id
            where m.kuri_id = k.id
              and m.status = 'ACTIVE'::public.membership_status
              and u.id = (select auth.uid())
          )
        )
      )
  )
);

commit;