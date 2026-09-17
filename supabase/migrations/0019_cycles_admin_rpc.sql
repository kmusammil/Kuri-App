begin;

-- Historical migration note: this file originally used CREATE OR REPLACE for
-- list_cycles_for_admin(), but that function already existed remotely with a
-- different return shape. The correction belongs in migration 0020.
-- Keep 0019 as an inert migration so db push can advance to 0020 without
-- attempting to mutate the incompatible existing function.

commit;
