-- ============================================================================
-- BTP — CORRECTION 2 : commission lue depuis la config (plus de 5% codé en dur).
-- release_construction_milestone_atomic utilisait round(m.amount * 0.05) alors
-- que service_types('construction').commission_rate = 10.00 (%). On lit la vraie
-- commission depuis service_types. TOUT le reste de la fonction est IDENTIQUE à
-- l'original (20260615170000) : verrou FOR UPDATE, client-only, idempotence,
-- v_pdg depuis pdg_management, crédits via credit_user_wallet_safe.
-- Grants INCHANGÉS : service_role uniquement (RPC appelée par le backend).
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.release_construction_milestone_atomic(p_milestone_id uuid, p_actor_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE m public.construction_milestones%ROWTYPE; v_client uuid; v_provider uuid; v_psid uuid; v_commission numeric; v_pdg uuid; v_rate numeric;
BEGIN
  SELECT * INTO m FROM public.construction_milestones WHERE id = p_milestone_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'MILESTONE_NOT_FOUND'; END IF;
  SELECT client_user_id, professional_service_id INTO v_client, v_psid FROM public.construction_projects WHERE id = m.project_id;
  IF p_actor_user_id <> v_client THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF m.status = 'released' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF m.status <> 'funded' THEN RAISE EXCEPTION 'NOT_FUNDED'; END IF;

  SELECT user_id INTO v_provider FROM public.professional_services WHERE id = v_psid;

  -- ✅ Commission lue depuis service_types.commission_rate (POURCENTAGE, ex 10.00 = 10%)
  SELECT st.commission_rate INTO v_rate
  FROM public.professional_services ps
  JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = v_psid;
  v_rate := COALESCE(v_rate, 5.0);                 -- repli prudent si NULL (ancien comportement)
  v_commission := round(m.amount * v_rate / 100.0);

  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  PERFORM public.credit_user_wallet_safe(v_provider, m.amount - v_commission, 'GNF', 'btp_milestone_release', m.id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'btp_milestone_commission', m.id::text);
  END IF;
  UPDATE public.construction_milestones SET status = 'released', released_at = now() WHERE id = p_milestone_id;
  RETURN jsonb_build_object('success', true, 'released', m.amount - v_commission, 'commission', v_commission, 'rate', v_rate);
END;
$$;

-- Grants IDENTIQUES à l'original (service_role uniquement)
REVOKE EXECUTE ON FUNCTION public.release_construction_milestone_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_construction_milestone_atomic(uuid, uuid) TO service_role;

DO $$
BEGIN
  RAISE NOTICE '✅ Commission BTP dynamique (service_types.commission_rate)';
END; $$;

COMMIT;
