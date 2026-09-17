begin;

-- Historical repair: migration 0021 may already exist in the remote migration
-- history. Keep this file inert so it does not fail with a duplicate version.
-- The cycle detail RPCs are installed by migration 0022.

commit;
