begin;

select plan(3);

select ok(
  exists(
    select 1
    from pg_policy
    where schemaname='public'
      and tablename='kuri_announcements'
      and policyname='kuri_announcements_select'
      and cmd='SELECT'
  ),
  'Kuri announcement SELECT policy exists'
);

select ok(
  exists(
    select 1
    from pg_policies
    where schemaname='public'
      and tablename='kuri_announcements'
      and policyname='kuri_announcements_select'
      and qual like '%memberships%'
  ),
  'Published announcement visibility is restricted to Kuri membership or administration'
);

select ok(
  not exists(
    select 1
    from pg_policies
    where schemaname='public'
      and tablename='kuri_announcements'
      and cmd in ('INSERT','UPDATE','DELETE')
  ),
  'No direct client mutation policy exists'
);

select * from finish();
rollback;