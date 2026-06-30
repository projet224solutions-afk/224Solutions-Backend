-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 4 (flux DEVIS / BTP) — commission agent sur le paiement de devis en ligne.
-- ════════════════════════════════════════════════════════════════════════════
-- pay_quote_atomic (non-escrow) ET release_quote_atomic (escrow validé) créditent
-- DÉJÀ le PDG de v_commission → on ajoute credit_agent_commission (débite 20%,
-- Étape 1) → net 80/20. Un seul tire par devis (non-escrow→pay, escrow→release),
-- idempotent par quote_id. Devis payé wallet = EN LIGNE. Fonctions reproduites à
-- l'identique + l'appel commission après le crédit PDG (non bloquant).
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

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

  PERFORM public.wallet_debit_internal(p_actor_user_id, q.total_amount, 'Paiement devis : ' || q.title, 'quote-pay-' || p_quote_id::text);

  IF q.escrow THEN
    -- Fonds séquestrés (libérés à la validation du client → commission à release_quote_atomic)
    UPDATE public.service_quotes SET status = 'paid', escrow_status = 'held', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', true);
  ELSE
    v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def);
    v_commission := round(q.total_amount * v_rate / 100.0);
    SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
    PERFORM public.credit_user_wallet_safe(v_provider, q.total_amount - v_commission, 'GNF', 'quote_payment', p_quote_id::text);
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
    END IF;
    -- ✅ COMMISSION AGENT (devis = wallet, en ligne). PDG crédité → 20% débité (Étape 1).
    IF v_commission > 0 THEN
      BEGIN
        PERFORM public.credit_agent_commission(p_actor_user_id, v_commission, 'quote', p_quote_id,
          jsonb_build_object('currency', 'GNF', 'flow', 'quote', 'quote_id', p_quote_id));
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'commission agent devis non appliquée (quote %): %', p_quote_id, SQLERRM;
      END;
    END IF;
    UPDATE public.service_quotes SET status = 'paid', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', false);
  END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pay_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_quote_atomic(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.release_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_code text; v_def numeric; v_rate numeric; v_commission numeric; v_pdg uuid;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF q.client_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF q.escrow_status = 'released' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF NOT q.escrow OR q.escrow_status <> 'held' THEN RAISE EXCEPTION 'NOT_HELD'; END IF;

  SELECT ps.user_id, st.code, COALESCE(st.commission_rate, 10)
    INTO v_provider, v_code, v_def
  FROM public.professional_services ps JOIN public.service_types st ON st.id = ps.service_type_id
  WHERE ps.id = q.professional_service_id;

  v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def);
  v_commission := round(q.total_amount * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  PERFORM public.credit_user_wallet_safe(v_provider, q.total_amount - v_commission, 'GNF', 'quote_release', p_quote_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
  END IF;
  -- ✅ COMMISSION AGENT à la libération escrow. PDG crédité → 20% débité (Étape 1).
  IF v_commission > 0 THEN
    BEGIN
      PERFORM public.credit_agent_commission(q.client_user_id, v_commission, 'quote', p_quote_id,
        jsonb_build_object('currency', 'GNF', 'flow', 'quote', 'quote_id', p_quote_id, 'escrow', true));
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'commission agent devis (release) non appliquée (quote %): %', p_quote_id, SQLERRM;
    END;
  END IF;
  UPDATE public.service_quotes SET escrow_status = 'released', status = 'completed', completed_at = now() WHERE id = p_quote_id;
  RETURN jsonb_build_object('success', true, 'released', q.total_amount - v_commission);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) TO service_role;

DO $$ BEGIN RAISE NOTICE '✅ pay_quote_atomic + release_quote_atomic : commission agent branchée'; END $$;

COMMIT;
