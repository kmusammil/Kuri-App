-- MEMBERSHIP-002: enrollment closure is independent of Kuri activation.
-- Enrollment may be closed while a Kuri is OPEN or already ACTIVE.
-- Closing enrollment does not transition Kuri lifecycle state.

CREATE OR REPLACE FUNCTION public.close_kuri_enrollment_for_admin(
  target_kuri_id uuid
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  current_status public.kuri_status;
  target_closed_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT k.status,k.enrollment_closed_at
    INTO current_status,target_closed_at
  FROM public.kuris k
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(
      k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Kuri not found or you do not have permission to manage enrollment.';
  END IF;

  IF current_status NOT IN ('OPEN','ACTIVE') THEN
    RAISE EXCEPTION 'Kuri enrollment can only be closed while the Kuri is OPEN or ACTIVE.';
  END IF;

  IF target_closed_at IS NULL THEN
    UPDATE public.kuris
    SET enrollment_closed_at=now(),updated_at=now()
    WHERE id=target_kuri_id
    RETURNING enrollment_closed_at INTO target_closed_at;
  END IF;

  RETURN target_closed_at;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.close_kuri_enrollment_for_admin(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.close_kuri_enrollment_for_admin(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.close_kuri_enrollment_for_admin(uuid) TO authenticated;
