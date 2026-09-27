BEGIN;

CREATE OR REPLACE FUNCTION public.create_person_for_admin(registered_name text, display_name text DEFAULT NULL::text, address text DEFAULT NULL::text, notes text DEFAULT NULL::text, phone text DEFAULT NULL::text, email text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  target_org_id uuid;
  admin_org_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'You must be signed in.';
  END IF;

  SELECT count(DISTINCT ou.organization_id)
    INTO admin_org_count
  FROM public.organization_users ou
  WHERE ou.user_id=auth.uid()
    AND ou.role=ANY(ARRAY['MAIN_ADMIN','ADMIN']::public.app_role[]);

  IF admin_org_count=0 THEN
    RAISE EXCEPTION 'You do not have permission to add people.';
  ELSIF admin_org_count>1 THEN
    RAISE EXCEPTION 'Organization context is required. Use create_person_for_org_admin.';
  END IF;

  SELECT ou.organization_id
    INTO target_org_id
  FROM public.organization_users ou
  WHERE ou.user_id=auth.uid()
    AND ou.role=ANY(ARRAY['MAIN_ADMIN','ADMIN']::public.app_role[])
  ORDER BY ou.organization_id::text
  LIMIT 1;

  IF target_org_id IS NULL THEN
    RAISE EXCEPTION 'You do not have permission to add people.';
  END IF;

  RETURN public.create_person_for_org_admin(
    target_org_id,
    registered_name,
    display_name,
    address,
    notes,
    phone,
    email
  );
END;
$function$


REVOKE ALL ON FUNCTION public.create_person_for_admin(text,text,text,text,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_person_for_admin(text,text,text,text,text,text) TO authenticated;

COMMIT;