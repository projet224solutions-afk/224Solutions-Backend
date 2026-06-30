-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 4 (fondation) — Primitif réutilisable : recette plateforme + commission agent.
-- ════════════════════════════════════════════════════════════════════════════
-- Modèle (décision Thierno, option 2) : pour qu'un flux PROXIMITÉ (taxi, loyer,
-- beauté, BTP…) puisse verser une commission agent SANS drainer le PDG, on doit
-- d'abord CRÉDITER le PDG de sa part plateforme (le revenu reconnu dans son wallet),
-- PUIS la commission agent en débite 20% (Étape 1) → net 80% PDG / 20% agents.
--
-- Ce primitif fait les deux, atomiquement et IDEMPOTEMMENT :
--   1. credit_user_wallet_safe(PDG, fee, GNF, source, ref) — idempotent (source,ref).
--   2. credit_agent_commission(buyer, fee, source, ref) — débite 20% du PDG (Étape 1),
--      idempotent (agent_id, transaction_id). Non bloquant.
--
-- À appeler UNIQUEMENT sur paiement EN LIGNE (jamais cash), avec p_platform_fee = la
-- PART PLATEFORME réelle du flux (jamais le montant total). Le marketplace n'utilise
-- PAS ce primitif (create_order_core PHASE 6 crédite déjà le PDG + orders.routes
-- appelle déjà la commission) → réservé aux flux proximité non encore branchés.
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.apply_platform_commission(
  p_buyer_user_id uuid,
  p_platform_fee  numeric,   -- part plateforme du flux (GNF), PAS le total
  p_source        text,      -- ex: 'taxi', 'rent', 'beauty', 'quote'
  p_reference     uuid,      -- id du flux (ride/lease/booking/quote) — anti-doublon
  p_metadata      jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_pdg    uuid := public.get_pdg_user_id();
  v_credit jsonb;
  v_comm   jsonb;
BEGIN
  IF p_platform_fee IS NULL OR p_platform_fee <= 0 THEN
    RETURN jsonb_build_object('success', true, 'skipped', 'no_fee');
  END IF;
  IF v_pdg IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PDG_INTROUVABLE');
  END IF;

  -- 1) RECETTE PLATEFORME : créditer le PDG de sa part (idempotent par source+ref).
  --    Sans ça, le débit de la commission (étape 2) viderait le PDG sans revenu en face.
  v_credit := public.credit_user_wallet_safe(
    v_pdg, p_platform_fee, 'GNF', 'platform_fee_' || p_source, p_reference::text);

  -- 2) COMMISSION AGENT : débite 20% du PDG → net 80% (Étape 1). Non bloquant : un
  --    souci de commission ne doit pas casser le paiement appelant.
  BEGIN
    v_comm := public.credit_agent_commission(
      p_buyer_user_id, p_platform_fee, p_source, p_reference,
      p_metadata || jsonb_build_object('currency', 'GNF', 'flow', p_source));
  EXCEPTION WHEN OTHERS THEN
    v_comm := jsonb_build_object('success', false, 'error', SQLERRM);
  END;

  RETURN jsonb_build_object('success', true,
    'platform_fee', p_platform_fee, 'pdg_credit', v_credit, 'commission', v_comm);
END;
$$;

REVOKE ALL ON FUNCTION public.apply_platform_commission(uuid, numeric, text, uuid, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.apply_platform_commission(uuid, numeric, text, uuid, jsonb) TO service_role;

DO $$ BEGIN
  RAISE NOTICE '✅ apply_platform_commission : recette PDG + commission agent (option 2)';
END $$;

COMMIT;
