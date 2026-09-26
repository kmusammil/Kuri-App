BEGIN;

CREATE OR REPLACE FUNCTION public.get_draw_session_for_admin(target_cycle_id uuid)
RETURNS TABLE(
  id uuid,kuri_id uuid,cycle_id uuid,conducted_by uuid,status public.draw_status,
  started_at timestamptz,completed_at timestamptz,created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
  SELECT d.id,d.kuri_id,d.cycle_id,d.conducted_by,d.status,d.started_at,d.completed_at,d.created_at
  FROM public.draw_sessions d
  JOIN public.cycles c ON c.id=d.cycle_id
  WHERE d.cycle_id=target_cycle_id
    AND public.has_kuri_admin_role(
      d.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    );
$$;

CREATE OR REPLACE FUNCTION public.get_draw_selections_for_admin(target_cycle_id uuid)
RETURNS TABLE(
  selection_id uuid,selection_order integer,membership_id uuid,membership_number text,
  registered_name text,display_name text,randomization_id text,selected_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
  SELECT s.id,s.selection_order,m.id,m.membership_number,p.registered_name,p.display_name,
         s.randomization_id,s.selected_at
  FROM public.draw_selections s
  JOIN public.draw_sessions d ON d.id=s.draw_session_id
  JOIN public.cycles c ON c.id=d.cycle_id
  JOIN public.memberships m ON m.id=s.membership_id
  JOIN public.people p ON p.id=m.person_id
  WHERE c.id=target_cycle_id
    AND public.has_kuri_admin_role(
      d.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY s.selection_order;
$$;

CREATE OR REPLACE FUNCTION public.list_draw_pool_for_admin(target_cycle_id uuid)
RETURNS TABLE(
  entry_id uuid,membership_id uuid,membership_number text,registered_name text,
  display_name text,system_eligible boolean,admin_included boolean,override boolean,
  override_reason text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
  SELECT e.id,m.id,m.membership_number,p.registered_name,p.display_name,
         e.system_eligible,e.admin_included,e.override,e.override_reason
  FROM public.draw_pool_entries e
  JOIN public.draw_sessions d ON d.id=e.draw_session_id
  JOIN public.memberships m ON m.id=e.membership_id
  JOIN public.people p ON p.id=m.person_id
  JOIN public.cycles c ON c.id=d.cycle_id
  WHERE c.id=target_cycle_id
    AND public.has_kuri_admin_role(
      d.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  ORDER BY m.membership_number;
$$;

CREATE OR REPLACE FUNCTION public.get_monthly_winners_for_admin(target_cycle_id uuid)
RETURNS TABLE(
  winner_id uuid,person_id uuid,registered_name text,display_name text,selection_source text,
  finalized_by uuid,finalized_at timestamptz,membership_numbers text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path=public
AS $$
  SELECT mw.id,mw.person_id,p.registered_name,p.display_name,mw.selection_source::text,
         mw.finalized_by,mw.finalized_at,
         string_agg(m.membership_number, ', ' ORDER BY m.membership_number)
  FROM public.monthly_winners mw
  JOIN public.people p ON p.id=mw.person_id
  LEFT JOIN public.monthly_winner_memberships mwm ON mwm.monthly_winner_id=mw.id
  LEFT JOIN public.memberships m ON m.id=mwm.membership_id
  JOIN public.cycles c ON c.id=mw.cycle_id
  WHERE mw.cycle_id=target_cycle_id
    AND public.has_kuri_admin_role(
      c.kuri_id,
      ARRAY['MAIN_ADMIN','ADMIN']::public.kuri_admin_role[]
    )
  GROUP BY mw.id,mw.person_id,p.registered_name,p.display_name,
           mw.selection_source,mw.finalized_by,mw.finalized_at
  ORDER BY mw.finalized_at,mw.id;
$$;

REVOKE ALL ON FUNCTION public.get_draw_session_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_draw_selections_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.list_draw_pool_for_admin(uuid) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_monthly_winners_for_admin(uuid) FROM PUBLIC,anon;

GRANT EXECUTE ON FUNCTION public.get_draw_session_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_draw_selections_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_draw_pool_for_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_monthly_winners_for_admin(uuid) TO authenticated;

COMMIT;