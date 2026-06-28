-- ============================================================================
-- BTP — CORRECTION 3 : litige sur un jalon financé (escrow bloqué en cas de
-- désaccord). Le client OU le prestataire ouvre un litige sur un jalon 'funded'
-- non libéré ; un admin/pdg tranche : 'release' (→ prestataire) ou 'refund'
-- (→ client). Le mouvement d'argent RÉUTILISE les primitives existantes
-- (credit_user_wallet_safe), AUCUN second chemin de crédit. Atomique (FOR UPDATE),
-- idempotent (statut jalon + ref de crédit). RPC service_role (comme fund/release).
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.construction_milestone_disputes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  milestone_id  UUID NOT NULL REFERENCES public.construction_milestones(id) ON DELETE CASCADE,
  project_id    UUID NOT NULL REFERENCES public.construction_projects(id) ON DELETE CASCADE,
  opened_by     UUID NOT NULL,
  opener_role   TEXT NOT NULL CHECK (opener_role IN ('client','provider')),
  reason        TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved_released','resolved_refunded','cancelled')),
  resolution_note TEXT,
  resolved_by   UUID,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_cmile_disputes_status
  ON public.construction_milestone_disputes (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cmile_disputes_milestone
  ON public.construction_milestone_disputes (milestone_id);

ALTER TABLE public.construction_milestone_disputes ENABLE ROW LEVEL SECURITY;

-- Lecture : parties du projet (client + prestataire) + admin/pdg/ceo
DROP POLICY IF EXISTS cmile_disp_read ON public.construction_milestone_disputes;
CREATE POLICY cmile_disp_read ON public.construction_milestone_disputes
  FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.construction_projects p
            WHERE p.id = project_id
              AND (public.check_service_owner(p.professional_service_id)
                   OR p.client_user_id = auth.uid()))
    OR EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role IN ('admin','pdg','ceo'))
  );
-- Écritures via RPC SECURITY DEFINER uniquement (aucune policy INSERT/UPDATE).

-- ── RPC : ouvrir un litige (client OU prestataire, jalon 'funded') ───────────
CREATE OR REPLACE FUNCTION public.open_construction_milestone_dispute(
  p_milestone_id uuid,
  p_actor_user_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  m public.construction_milestones%ROWTYPE;
  v_client uuid; v_psid uuid; v_provider uuid;
  v_role text; v_dispute_id uuid;
BEGIN
  SELECT * INTO m FROM public.construction_milestones WHERE id = p_milestone_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'MILESTONE_NOT_FOUND'); END IF;
  IF m.status <> 'funded' THEN
    RETURN jsonb_build_object('success', false, 'error', 'ONLY_FUNDED_DISPUTABLE');
  END IF;

  SELECT client_user_id, professional_service_id INTO v_client, v_psid
  FROM public.construction_projects WHERE id = m.project_id;
  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = v_psid;

  IF p_actor_user_id = v_client THEN v_role := 'client';
  ELSIF p_actor_user_id = v_provider THEN v_role := 'provider';
  ELSE RETURN jsonb_build_object('success', false, 'error', 'NOT_A_PARTY'); END IF;

  IF p_reason IS NULL OR length(trim(p_reason)) < 5 THEN
    RETURN jsonb_build_object('success', false, 'error', 'REASON_REQUIRED');
  END IF;

  IF EXISTS (SELECT 1 FROM public.construction_milestone_disputes
             WHERE milestone_id = p_milestone_id AND status = 'open') THEN
    RETURN jsonb_build_object('success', false, 'error', 'DISPUTE_ALREADY_OPEN');
  END IF;

  INSERT INTO public.construction_milestone_disputes (milestone_id, project_id, opened_by, opener_role, reason)
  VALUES (p_milestone_id, m.project_id, p_actor_user_id, v_role, trim(p_reason))
  RETURNING id INTO v_dispute_id;

  RETURN jsonb_build_object('success', true, 'dispute_id', v_dispute_id);
END;
$$;

-- ── RPC : résoudre un litige (ADMIN/PDG) → libère OU rembourse (mouvement réel) ──
CREATE OR REPLACE FUNCTION public.resolve_construction_milestone_dispute(
  p_dispute_id uuid,
  p_actor_user_id uuid,
  p_decision text,           -- 'release' (→ prestataire) | 'refund' (→ client)
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  d public.construction_milestone_disputes%ROWTYPE;
  m public.construction_milestones%ROWTYPE;
  v_role text;
  v_client uuid; v_psid uuid; v_provider uuid; v_pdg uuid;
  v_rate numeric; v_commission numeric;
BEGIN
  -- Réservé admin/pdg/ceo
  SELECT role INTO v_role FROM public.profiles WHERE id = p_actor_user_id;
  IF v_role IS NULL OR v_role NOT IN ('admin','pdg','ceo') THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_AUTHORIZED');
  END IF;

  SELECT * INTO d FROM public.construction_milestone_disputes WHERE id = p_dispute_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'DISPUTE_NOT_FOUND'); END IF;
  IF d.status <> 'open' THEN RETURN jsonb_build_object('success', false, 'error', 'ALREADY_RESOLVED'); END IF;

  -- Verrou du jalon : doit toujours être 'funded' (l'argent est en séquestre)
  SELECT * INTO m FROM public.construction_milestones WHERE id = d.milestone_id FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'MILESTONE_NOT_FOUND'); END IF;
  IF m.status <> 'funded' THEN RETURN jsonb_build_object('success', false, 'error', 'MILESTONE_NOT_FUNDED'); END IF;

  SELECT client_user_id, professional_service_id INTO v_client, v_psid
  FROM public.construction_projects WHERE id = m.project_id;

  IF p_decision = 'release' THEN
    -- Libération vers le prestataire (mêmes primitives/refs que release_*_atomic)
    SELECT user_id INTO v_provider FROM public.professional_services WHERE id = v_psid;
    SELECT st.commission_rate INTO v_rate
    FROM public.professional_services ps JOIN public.service_types st ON st.id = ps.service_type_id
    WHERE ps.id = v_psid;
    v_rate := COALESCE(v_rate, 5.0);
    v_commission := round(m.amount * v_rate / 100.0);
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

    PERFORM public.credit_user_wallet_safe(v_provider, m.amount - v_commission, 'GNF', 'btp_milestone_release', m.id::text);
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'btp_milestone_commission', m.id::text);
    END IF;
    UPDATE public.construction_milestones SET status = 'released', released_at = now() WHERE id = m.id;

    UPDATE public.construction_milestone_disputes
      SET status='resolved_released', resolution_note=p_note, resolved_by=p_actor_user_id, resolved_at=now()
      WHERE id = p_dispute_id;
    RETURN jsonb_build_object('success', true, 'decision', 'released', 'amount', m.amount - v_commission, 'commission', v_commission);

  ELSIF p_decision = 'refund' THEN
    -- Remboursement du client : recrédite le montant débité au financement
    PERFORM public.credit_user_wallet_safe(v_client, m.amount, 'GNF', 'btp_milestone_refund', m.id::text);
    UPDATE public.construction_milestones SET status = 'cancelled' WHERE id = m.id;

    UPDATE public.construction_milestone_disputes
      SET status='resolved_refunded', resolution_note=p_note, resolved_by=p_actor_user_id, resolved_at=now()
      WHERE id = p_dispute_id;
    RETURN jsonb_build_object('success', true, 'decision', 'refunded', 'amount', m.amount);

  ELSE
    RETURN jsonb_build_object('success', false, 'error', 'BAD_DECISION');
  END IF;
END;
$$;

-- Grants : service_role uniquement (cohérent avec fund/release/claim ; le backend
-- mediera après verifyJWT, en passant l'actor_user_id authentifié).
REVOKE ALL ON FUNCTION public.open_construction_milestone_dispute(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.open_construction_milestone_dispute(uuid, uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.resolve_construction_milestone_dispute(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.resolve_construction_milestone_dispute(uuid, uuid, text, text) TO service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_tables WHERE tablename='construction_milestone_disputes')
  THEN RAISE EXCEPTION 'table litiges absente'; END IF;
  RAISE NOTICE '✅ Migration construction_milestone_dispute OK';
END; $$;

COMMIT;
