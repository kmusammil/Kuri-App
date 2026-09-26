CREATE OR REPLACE FUNCTION public.list_membership_exits_for_admin(target_kuri_id uuid)
RETURNS TABLE(
  exit_id uuid,membership_id uuid,membership_number text,registered_name text,display_name text,
  reason public.settlement_reason,exit_date date,refund_policy public.refund_policy,
  amount_contributed bigint,refund_amount bigint,status public.settlement_status,approved_by uuid,
  settled_at timestamptz,notes text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT me.id,m.id,m.membership_number,p.registered_name,p.display_name,
         me.reason,me.exit_date,me.refund_policy,me.amount_contributed,me.refund_amount,
         me.status,me.approved_by,me.settled_at,me.notes
  FROM public.membership_exits me
  JOIN public.memberships m ON m.id=me.membership_id
  JOIN public.people p ON p.id=m.person_id
  JOIN public.kuris k ON k.id=m.kuri_id
  WHERE k.id=target_kuri_id
    AND public.has_kuri_admin_role(k.id,ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[])
  ORDER BY me.exit_date DESC,m.membership_number;
$$;
REVOKE ALL ON FUNCTION public.list_membership_exits_for_admin(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_membership_exits_for_admin(uuid) TO authenticated;