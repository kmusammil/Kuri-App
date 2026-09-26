BEGIN;

DROP FUNCTION IF EXISTS public.run_random_draw_for_admin(uuid,integer);
DROP FUNCTION IF EXISTS public.finalize_draw_for_admin(uuid,uuid[]);

COMMIT;
