BEGIN;

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.run_random_draw_for_admin(uuid,integer,text)'::regprocedure
  )
  INTO v_def;

  v_def := replace(
    v_def,
    '  actor_user_id uuid := (SELECT auth.uid());',
    '  v_actor_user_id uuid := (SELECT auth.uid());'
  );
  v_def := replace(
    v_def,
    '  IF actor_user_id IS NULL THEN',
    '  IF v_actor_user_id IS NULL THEN'
  );
  v_def := replace(
    v_def,
    '    actor_user_id,target_kuri_id,''DRAW_RUN'',normalized_key,request_hash',
    '    v_actor_user_id,target_kuri_id,''DRAW_RUN'',normalized_key,request_hash'
  );
  v_def := replace(
    v_def,
    'WHERE f.actor_user_id=actor_user_id',
    'WHERE f.actor_user_id=v_actor_user_id'
  );

  EXECUTE v_def;
END
$$;

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(
    'public.finalize_draw_for_admin(uuid,uuid[],text)'::regprocedure
  )
  INTO v_def;

  v_def := replace(
    v_def,
    '  actor_user_id uuid := (SELECT auth.uid());',
    '  v_actor_user_id uuid := (SELECT auth.uid());'
  );
  v_def := replace(
    v_def,
    '  IF actor_user_id IS NULL THEN',
    '  IF v_actor_user_id IS NULL THEN'
  );
  v_def := replace(
    v_def,
    '    actor_user_id,target_kuri_id,''DRAW_FINALIZE'',normalized_key,request_hash',
    '    v_actor_user_id,target_kuri_id,''DRAW_FINALIZE'',normalized_key,request_hash'
  );
  v_def := replace(
    v_def,
    'WHERE f.actor_user_id=actor_user_id',
    'WHERE f.actor_user_id=v_actor_user_id'
  );

  EXECUTE v_def;
END
$$;

COMMIT;
