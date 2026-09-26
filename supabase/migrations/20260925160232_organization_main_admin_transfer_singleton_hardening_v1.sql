begin;

create unique index if not exists organization_users_one_main_admin_idx
on public.organization_users (organization_id)
where role = 'MAIN_ADMIN';

commit;