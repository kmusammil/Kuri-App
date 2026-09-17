begin;

-- Reconcile migration history that was already applied to the remote database.
-- The remote database has recorded 0011-0014, but those source files were later
-- removed. Mark those historical versions as reverted, then let the current
-- 0010 migration remain the final People migration in the source tree.

do $$
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    delete from supabase_migrations.schema_migrations
    where version in ('0011','0012','0013','0014');
  end if;
end;
$$;

commit;
