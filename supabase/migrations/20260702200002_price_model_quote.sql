-- ============================================================================
-- MODÈLE DE PRIX UNIFORME — DEVIS BTP/SERVICES (le prestataire reçoit tout)
-- ----------------------------------------------------------------------------
-- Avant : prestataire crédité de `total_amount − commission` (amputé), en direct
-- comme en escrow. Après (modèle marketplace) :
--   • Le CLIENT paie `total_amount + commission` (débit unique, vérif solde sur le total).
--   • DIRECT  : prestataire crédité du montant COMPLET, PDG de la commission.
--   • ESCROW  : commission prélevée HORS escrow au PAIEMENT (→ PDG) ; le montant
--     COMPLET reste séquestré ; à la libération, prestataire crédité du COMPLET
--     (sans re-déduire de commission).
-- Invariant : débit == crédit prestataire + crédit PDG (à la maille du cycle).
-- pay_installment_atomic (échéances vente à crédit) = pure comptabilité, sans
-- mouvement d'argent ni commission → NON concerné, non modifié.
-- ============================================================================

-- ── pay_quote_atomic : client paie total + commission ; direct OU escrow ────
CREATE OR REPLACE FUNCTION public.pay_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_code text; v_def numeric; v_rate numeric; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF q.status IN ('paid','completed') THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF q.status = 'cancelled' THEN RAISE EXCEPTION 'QUOTE_CANCELLED'; END IF;
  IF COALESCE(q.total_amount,0) <= 0 THEN RAISE EXCEPTION 'BAD_AMOUNT'; END IF;

  SELECT ps.user_id, st.code, COALESCE(st.commission_rate, 10)
    INTO v_provider, v_code, v_def
  FROM public.professional_services ps JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = q.professional_service_id;
  IF v_provider = p_actor_user_id THEN RAISE EXCEPTION 'OWN_QUOTE'; END IF;

  -- Commission calculée AVANT le débit (payée par le client EN PLUS du devis).
  v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def);
  v_commission := round(q.total_amount * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- Débit client = montant du devis + commission (vérif de solde sur le total).
  PERFORM public.wallet_debit_internal(p_actor_user_id, q.total_amount + v_commission, 'Paiement devis : ' || q.title || ' (+ commission)', 'quote-pay-' || p_quote_id::text);

  IF q.escrow THEN
    -- Escrow : le montant COMPLET (total_amount) reste séquestré (crédité au
    -- prestataire à la libération). La commission est prélevée HORS escrow ici.
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
      -- Commission AGENT au créateur du service (= le prestataire v_provider), débitée du PDG. Non bloquante.
      BEGIN
        PERFORM public.credit_agent_commission(v_provider, v_commission, 'quote', md5('quote-'||p_quote_id::text)::uuid,
          jsonb_build_object('currency','GNF','flow','quote','quote_id',p_quote_id));
      EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'commission agent devis non appliquée (%): %', p_quote_id, SQLERRM; END;
    END IF;
    UPDATE public.service_quotes SET status = 'paid', escrow_status = 'held', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', true);
  ELSE
    -- Direct : prestataire crédité du montant COMPLET, PDG de la commission.
    PERFORM public.credit_user_wallet_safe(v_provider, q.total_amount, 'GNF', 'quote_payment', p_quote_id::text);
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
      -- Commission AGENT au créateur du service (= le prestataire v_provider), débitée du PDG. Non bloquante.
      BEGIN
        PERFORM public.credit_agent_commission(v_provider, v_commission, 'quote', md5('quote-'||p_quote_id::text)::uuid,
          jsonb_build_object('currency','GNF','flow','quote','quote_id',p_quote_id));
      EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'commission agent devis non appliquée (%): %', p_quote_id, SQLERRM; END;
    END IF;
    UPDATE public.service_quotes SET status = 'paid', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', false);
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pay_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_quote_atomic(uuid, uuid) TO service_role;

-- ── release_quote_atomic : libère l'escrow → prestataire COMPLET (commission déjà prise) ──
CREATE OR REPLACE FUNCTION public.release_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF q.client_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF q.escrow_status = 'released' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF NOT q.escrow OR q.escrow_status <> 'held' THEN RAISE EXCEPTION 'NOT_HELD'; END IF;

  SELECT ps.user_id INTO v_provider
  FROM public.professional_services ps
  WHERE ps.id = q.professional_service_id;

  -- Le montant séquestré = total_amount COMPLET ; la commission a déjà été prélevée
  -- au paiement (hors escrow) → on NE re-déduit PAS de commission ici.
  PERFORM public.credit_user_wallet_safe(v_provider, q.total_amount, 'GNF', 'quote_release', p_quote_id::text);
  UPDATE public.service_quotes SET escrow_status = 'released', status = 'completed', completed_at = now() WHERE id = p_quote_id;
  RETURN jsonb_build_object('success', true, 'released', q.total_amount);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) TO service_role;

SELECT 'Modèle prix devis : prestataire reçoit le montant complet (direct + escrow), commission payée par le client.' AS status;
