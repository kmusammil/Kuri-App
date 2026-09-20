-- People / nominee RLS performance hardening
-- Keep auth identity evaluation statement-scoped and add FK covering indexes.

drop policy if exists people_select on public.people;

create policy people_select
on public.people
for select
to public
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = people.organization_id
      and ou.user_id = (select auth.uid())
  )
  or
  exists (
    select 1
    from public.users u
    where u.id = (select auth.uid())
      and u.person_id = people.id
  )
);

drop policy if exists nominees_select on public.nominees;

create policy nominees_select
on public.nominees
for select
to public
using (
  exists (
    select 1
    from public.users u
    where u.id = (select auth.uid())
      and u.person_id = nominees.person_id
  )
);

create index if not exists nominees_person_id_idx
  on public.nominees (person_id);

create index if not exists person_phones_person_id_idx
  on public.person_phones (person_id);

create index if not exists person_emails_person_id_idx
  on public.person_emails (person_id);

create index if not exists users_person_id_idx
  on public.users (person_id);
