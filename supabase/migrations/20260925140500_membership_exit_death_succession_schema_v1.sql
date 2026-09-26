-- Production reconciliation: membership exit, death verification, succession schema.
ALTER TABLE public.financial_idempotency_keys ADD COLUMN IF NOT EXISTS result_reference_id uuid;
ALTER TABLE public.financial_idempotency_keys DROP CONSTRAINT IF EXISTS financial_idempotency_keys_operation_type_check;
ALTER TABLE public.financial_idempotency_keys DROP CONSTRAINT IF EXISTS financial_idempotency_keys_check;
ALTER TABLE public.financial_idempotency_keys ADD CONSTRAINT financial_idempotency_keys_operation_type_check CHECK (
  operation_type = ANY (ARRAY[
    'PAYMENT_CREATE','PAYMENT_ALLOCATION','PAYOUT_PAYMENT','DRAW_RUN','DRAW_FINALIZE',
    'EXIT_CREATE','EXIT_APPROVE','EXIT_CANCEL','EXIT_REFUND','EXIT_SETTLE','DEATH_VERIFY',
    'DEATH_SETTLEMENT','SUCCESSION'
  ]::text[])
);
ALTER TABLE public.financial_idempotency_keys ADD CONSTRAINT financial_idempotency_keys_check CHECK (
  status='IN_PROGRESS'
  OR (operation_type='PAYMENT_CREATE' AND result_payment_id IS NOT NULL AND result_bigint IS NULL AND result_reference_id IS NULL AND completed_at IS NOT NULL)
  OR (operation_type='PAYOUT_PAYMENT' AND result_payment_id IS NULL AND result_bigint IS NULL AND result_reference_id IS NULL AND completed_at IS NOT NULL)
  OR (operation_type=ANY(ARRAY['PAYMENT_ALLOCATION','DRAW_RUN','DRAW_FINALIZE']::text[]) AND result_payment_id IS NULL AND result_bigint IS NOT NULL AND result_reference_id IS NULL AND completed_at IS NOT NULL)
  OR (operation_type=ANY(ARRAY['EXIT_CREATE','EXIT_APPROVE','EXIT_CANCEL','EXIT_REFUND','EXIT_SETTLE','DEATH_VERIFY','DEATH_SETTLEMENT','SUCCESSION']::text[])
      AND result_payment_id IS NULL AND result_bigint IS NULL AND result_reference_id IS NOT NULL AND completed_at IS NOT NULL)
);
ALTER TABLE public.membership_exits ADD COLUMN IF NOT EXISTS requested_at timestamptz;
ALTER TABLE public.membership_exits ADD COLUMN IF NOT EXISTS death_date_verified_at timestamptz;
ALTER TABLE public.membership_exits ADD COLUMN IF NOT EXISTS death_date_verified_by uuid;
ALTER TABLE public.membership_exits DROP CONSTRAINT IF EXISTS membership_exits_death_date_verified_by_fkey;
ALTER TABLE public.membership_exits ADD CONSTRAINT membership_exits_death_date_verified_by_fkey
  FOREIGN KEY (death_date_verified_by) REFERENCES public.users(id) ON DELETE SET NULL;
ALTER TABLE public.memberships ADD COLUMN IF NOT EXISTS current_holder_person_id uuid;
ALTER TABLE public.memberships DROP CONSTRAINT IF EXISTS memberships_current_holder_person_id_fkey;
ALTER TABLE public.memberships ADD CONSTRAINT memberships_current_holder_person_id_fkey
  FOREIGN KEY (current_holder_person_id) REFERENCES public.people(id) ON DELETE RESTRICT;
CREATE INDEX IF NOT EXISTS memberships_kuri_current_holder_idx ON public.memberships(kuri_id,current_holder_person_id);

CREATE TABLE IF NOT EXISTS public.membership_successions(
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  membership_id uuid NOT NULL REFERENCES public.memberships(id) ON DELETE RESTRICT,
  membership_exit_id uuid NOT NULL UNIQUE REFERENCES public.membership_exits(id) ON DELETE RESTRICT,
  original_person_id uuid NOT NULL REFERENCES public.people(id) ON DELETE RESTRICT,
  successor_person_id uuid NOT NULL REFERENCES public.people(id) ON DELETE RESTRICT,
  nominee_id uuid NOT NULL REFERENCES public.nominees(id) ON DELETE RESTRICT,
  succeeded_at timestamptz NOT NULL DEFAULT now(),
  recorded_by uuid REFERENCES public.users(id) ON DELETE SET NULL,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT membership_successions_one_per_membership UNIQUE(membership_id)
);
ALTER TABLE public.membership_successions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.membership_successions FROM PUBLIC,anon,authenticated;
ALTER TABLE public.membership_exit_refund_transactions DROP CONSTRAINT IF EXISTS membership_exit_refund_transactions_membership_exit_id_key;
CREATE INDEX IF NOT EXISTS membership_exit_refunds_exit_id_idx ON public.membership_exit_refund_transactions(membership_exit_id);

CREATE OR REPLACE FUNCTION public.enforce_membership_current_holder_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_kuri_org_id uuid; v_holder_org_id uuid;
BEGIN
  IF NEW.current_holder_person_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.current_holder_person_id=NEW.person_id THEN RAISE EXCEPTION 'Current holder must differ from the original member identity.'; END IF;
  SELECT k.organization_id INTO v_kuri_org_id FROM public.kuris k WHERE k.id=NEW.kuri_id;
  SELECT p.organization_id INTO v_holder_org_id FROM public.people p WHERE p.id=NEW.current_holder_person_id;
  IF v_kuri_org_id IS NULL OR v_holder_org_id IS NULL OR v_kuri_org_id<>v_holder_org_id THEN RAISE EXCEPTION 'Current holder does not belong to the Kuri organization.'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.membership_successions s WHERE s.membership_id=NEW.id AND s.successor_person_id=NEW.current_holder_person_id) THEN RAISE EXCEPTION 'Current holder can only be changed through a recorded succession.'; END IF;
  IF TG_OP='UPDATE' AND OLD.current_holder_person_id IS NOT NULL AND OLD.current_holder_person_id<>NEW.current_holder_person_id THEN RAISE EXCEPTION 'Current holder is immutable after succession.'; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS aa_memberships_current_holder_guard ON public.memberships;
CREATE TRIGGER aa_memberships_current_holder_guard BEFORE INSERT OR UPDATE OF current_holder_person_id ON public.memberships
FOR EACH ROW EXECUTE FUNCTION public.enforce_membership_current_holder_identity();

CREATE OR REPLACE FUNCTION public.enforce_membership_succession_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_kuri_id uuid; v_original_person_id uuid; v_org_id uuid; v_original_org_id uuid; v_successor_org_id uuid; v_nominee_person_id uuid;
BEGIN
  SELECT m.kuri_id,m.person_id,k.organization_id INTO v_kuri_id,v_original_person_id,v_org_id
  FROM public.memberships m JOIN public.kuris k ON k.id=m.kuri_id WHERE m.id=NEW.membership_id FOR UPDATE;
  IF v_kuri_id IS NULL THEN RAISE EXCEPTION 'Membership for succession was not found.'; END IF;
  SELECT p.organization_id INTO v_original_org_id FROM public.people p WHERE p.id=NEW.original_person_id;
  SELECT p.organization_id INTO v_successor_org_id FROM public.people p WHERE p.id=NEW.successor_person_id;
  SELECT n.person_id INTO v_nominee_person_id FROM public.nominees n WHERE n.id=NEW.nominee_id;
  IF NEW.original_person_id<>v_original_person_id THEN RAISE EXCEPTION 'Succession original person does not match the membership history.'; END IF;
  IF NEW.successor_person_id=NEW.original_person_id THEN RAISE EXCEPTION 'A member cannot succeed themselves.'; END IF;
  IF v_original_org_id IS DISTINCT FROM v_org_id OR v_successor_org_id IS DISTINCT FROM v_org_id THEN RAISE EXCEPTION 'Succession identities must belong to the Kuri organization.'; END IF;
  IF v_nominee_person_id IS DISTINCT FROM v_original_person_id THEN RAISE EXCEPTION 'The selected nominee is not registered for the original member.'; END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.membership_exits me
    WHERE me.id=NEW.membership_exit_id AND me.membership_id=NEW.membership_id AND me.reason='DEATH' AND me.status='SETTLED'
      AND me.settled_to_nominee_id=NEW.nominee_id AND me.death_date_verified_at IS NOT NULL
  ) THEN RAISE EXCEPTION 'Succession requires a settled, verified death case with the same nominee.'; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS membership_successions_identity_guard ON public.membership_successions;
CREATE TRIGGER membership_successions_identity_guard BEFORE INSERT ON public.membership_successions
FOR EACH ROW EXECUTE FUNCTION public.enforce_membership_succession_identity();

CREATE OR REPLACE FUNCTION public.prevent_membership_succession_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF TG_OP IN ('UPDATE','DELETE') THEN RAISE EXCEPTION 'Membership succession records are append-only.'; END IF;
  RETURN COALESCE(NEW,OLD);
END $$;
DROP TRIGGER IF EXISTS membership_successions_append_only ON public.membership_successions;
CREATE TRIGGER membership_successions_append_only BEFORE UPDATE OR DELETE ON public.membership_successions
FOR EACH ROW EXECUTE FUNCTION public.prevent_membership_succession_mutation();
