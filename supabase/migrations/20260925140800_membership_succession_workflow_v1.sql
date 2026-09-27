-- Production reconciliation: nominee-based succession workflow.
CREATE OR REPLACE FUNCTION public.create_membership_succession_for_admin(target_exit_id uuid, target_nominee_id uuid, succession_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_kuri_id uuid;
  v_org_id uuid;
  v_membership_id uuid;
  v_original_person_id uuid;
  v_exit_status public.settlement_status;
  v_exit_reason public.settlement_reason;
  v_settled_nominee uuid;
  v_nominee_name text;
  v_nominee_relationship text;
  v_nominee_phone text;
  v_nominee_address text;
  v_nominee_notes text;
  v_successor_person_id uuid;
  v_succession_id uuid;
  v_hash text;
  v_key text;
  v_idem public.financial_idempotency_keys%rowtype;
  v_notes text;
BEGIN
  IF v_actor IS NULL THEN RAISE EXCEPTION 'You must be signed in.'; END IF;

  SELECT m.kuri_id,k.organization_id,m.id,m.person_id,me.status,me.reason,me.settled_to_nominee_id
    INTO v_kuri_id,v_org_id,v_membership_id,v_original_person_id,v_exit_status,v_exit_reason,v_settled_nominee
  FROM public.membership_exits me
  JOIN public.memberships m ON m.id=me.membership_id
  JOIN public.kuris k ON k.id=m.kuri_id
  WHERE me.id=target_exit_id
  FOR UPDATE OF me,m,k;

  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Death exit record not found.'; END IF;
  IF NOT public.has_kuri_admin_role(v_kuri_id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]) THEN
    RAISE EXCEPTION 'You do not have permission to record succession for this Kuri.';
  END IF;

  v_notes:=nullif(btrim(create_membership_succession_for_admin.succession_notes),'');
  v_hash:=encode(extensions.digest(jsonb_build_array(
    target_exit_id::text,target_nominee_id::text,coalesce(v_notes,'')
  )::text,'sha256'),'hex');
  v_key:='AUTO-SUCCESSION-'||v_hash;

  INSERT INTO public.financial_idempotency_keys(actor_user_id,kuri_id,operation_type,idempotency_key,request_hash)
  VALUES(v_actor,v_kuri_id,'SUCCESSION',v_key,v_hash)
  ON CONFLICT(actor_user_id,operation_type,idempotency_key) DO NOTHING;

  SELECT * INTO v_idem
  FROM public.financial_idempotency_keys
  WHERE actor_user_id=v_actor AND operation_type='SUCCESSION' AND idempotency_key=v_key FOR UPDATE;

  IF v_idem.request_hash<>v_hash THEN RAISE EXCEPTION 'Succession replay hash mismatch.'; END IF;
  IF v_idem.status='COMPLETED' THEN RETURN v_idem.result_reference_id; END IF;

  IF v_exit_reason<>'DEATH' OR v_exit_status<>'SETTLED' THEN
    RAISE EXCEPTION 'Succession requires a settled death exit.';
  END IF;
  IF v_settled_nominee IS DISTINCT FROM target_nominee_id THEN
    RAISE EXCEPTION 'Succession requires the nominee recorded on the death settlement.';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.membership_exits
    WHERE id=target_exit_id AND death_date_verified_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Succession requires a verified death date.';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.membership_successions s
    WHERE s.membership_id=v_membership_id
  ) THEN
    RAISE EXCEPTION 'This membership already has a recorded succession.';
  END IF;

  SELECT n.name,n.relationship,n.phone,n.address,n.notes
    INTO v_nominee_name,v_nominee_relationship,v_nominee_phone,v_nominee_address,v_nominee_notes
  FROM public.nominees n
  WHERE n.id=target_nominee_id AND n.person_id=v_original_person_id;

  IF v_nominee_name IS NULL THEN
    RAISE EXCEPTION 'Selected nominee is not registered for the original member.';
  END IF;

  INSERT INTO public.people(
    registered_name,display_name,address,notes,organization_id
  )
  VALUES(
    btrim(v_nominee_name),
    btrim(v_nominee_name),
    nullif(btrim(v_nominee_address),''),
    concat_ws(
      ' | ',
      nullif(btrim(v_nominee_notes),''),
      CASE WHEN v_nominee_relationship IS NULL THEN NULL
           ELSE 'Registered nominee relationship: '||btrim(v_nominee_relationship) END,
      CASE WHEN v_nominee_phone IS NULL THEN NULL
           ELSE 'Registered nominee phone: '||btrim(v_nominee_phone) END
    ),
    v_org_id
  )
  RETURNING id INTO v_successor_person_id;

  INSERT INTO public.membership_successions(
    membership_id,membership_exit_id,original_person_id,successor_person_id,
    nominee_id,recorded_by,notes
  )
  VALUES(
    v_membership_id,target_exit_id,v_original_person_id,v_successor_person_id,
    target_nominee_id,(SELECT id FROM public.users WHERE id=v_actor),v_notes
  )
  RETURNING id INTO v_succession_id;

  UPDATE public.memberships
  SET current_holder_person_id=v_successor_person_id,status='ACTIVE'
  WHERE id=v_membership_id AND status='EXITED';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Membership must be EXITED before succession can activate the successor.';
  END IF;

  UPDATE public.financial_idempotency_keys
  SET status='COMPLETED',result_reference_id=v_succession_id,completed_at=now()
  WHERE id=v_idem.id;

  RETURN v_succession_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_membership_succession_for_admin(target_membership_id uuid)
 RETURNS TABLE(succession_id uuid, membership_id uuid, membership_exit_id uuid, original_person_id uuid, original_registered_name text, successor_person_id uuid, successor_registered_name text, nominee_id uuid, nominee_name text, nominee_relationship text, succeeded_at timestamp with time zone, recorded_by uuid, notes text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT s.id,s.membership_id,s.membership_exit_id,s.original_person_id,
         op.registered_name,s.successor_person_id,sp.registered_name,
         s.nominee_id,n.name,n.relationship,s.succeeded_at,s.recorded_by,s.notes
  FROM public.membership_successions s
  JOIN public.memberships m ON m.id=s.membership_id
  JOIN public.kuris k ON k.id=m.kuri_id
  JOIN public.people op ON op.id=s.original_person_id
  JOIN public.people sp ON sp.id=s.successor_person_id
  JOIN public.nominees n ON n.id=s.nominee_id
  WHERE s.membership_id=target_membership_id
    AND public.has_kuri_admin_role(k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]);
$function$;
REVOKE ALL ON FUNCTION public.create_membership_succession_for_admin(uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_membership_succession_for_admin(uuid,uuid,text) TO authenticated;
REVOKE ALL ON FUNCTION public.get_membership_succession_for_admin(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_membership_succession_for_admin(uuid) TO authenticated;