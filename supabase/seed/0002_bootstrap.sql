-- Bootstrap data for the first Kuri-App organization.
-- Replace the placeholder UUID with the auth user ID of the first admin after account creation.
-- This seed is intentionally kept separate from the foundation migration.

-- INSERT INTO public.organizations (id, name, description)
-- VALUES ('00000000-0000-0000-0000-000000000001', 'Kuri-App Demo Organization', 'Initial Kuri-App organization');

-- INSERT INTO public.organization_users (organization_id, user_id, role)
-- VALUES ('00000000-0000-0000-0000-000000000001', 'REPLACE_WITH_AUTH_USER_UUID', 'MAIN_ADMIN');
