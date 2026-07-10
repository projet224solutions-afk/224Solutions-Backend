-- ============================================================================
-- DURCISSEMENT ATOMIQUE — DEVIS : garde de crédit prestataire (ROLLBACK si échec)
-- ----------------------------------------------------------------------------
-- Idempotence déjà OK (source_txn_id = quote_id, unique ; gardes de statut/escrow).
-- On ajoute la GARDE : le crédit prestataire (direct + libération escrow) DOIT
-- avoir eu lieu (ni skip fantôme ni 0) sinon EXCEPTION → ROLLBACK total (atomique) :
-- on ne marque JAMAIS un devis payé/complété sans que le prestataire soit crédité.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.pay_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_code text; v_def numeric; v_rate numeric; v_commission numeric; v_pdg uuid;
        v_res jsonb; v_got numeric;
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

  v_rate := public.resolve_service_commission_rate(v_provider, v_code, v_def);
  v_commission := round(q.total_amount * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  PERFORM public.wallet_debit_internal(p_actor_user_id, q.total_amount + v_commission, 'Paiement devis : ' || q.title || ' (+ commission)', 'quote-pay-' || p_quote_id::text);

  IF q.escrow THEN
    -- Escrow : montant COMPLET séquestré (crédité à la libération). Commission hors-escrow ici.
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
      BEGIN
        PERFORM public.credit_agent_commission(v_provider, v_commission, 'quote', md5('quote-'||p_quote_id::text)::uuid,
          jsonb_build_object('currency','GNF','flow','quote','quote_id',p_quote_id));
      EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'commission agent devis non appliquée (%): %', p_quote_id, SQLERRM; END;
    END IF;
    UPDATE public.service_quotes SET status = 'paid', escrow_status = 'held', paid_at = now(),
      client_user_id = COALESCE(client_user_id, p_actor_user_id) WHERE id = p_quote_id;
    RETURN jsonb_build_object('success', true, 'escrow', true);
  ELSE
    -- Direct : prestataire crédité du montant COMPLET (garde : sinon ROLLBACK).
    v_res := public.credit_user_wallet_safe(v_provider, q.total_amount, 'GNF', 'quote_payment', p_quote_id::text);
    v_got := COALESCE((v_res->>'credited')::numeric,0) + COALESCE((v_res->>'quarantined')::numeric,0);
    IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN RAISE EXCEPTION 'CREDIT_PRESTATAIRE_ECHOUE (%)', COALESCE(v_res->>'error','?'); END IF;
    IF v_pdg IS NOT NULL AND v_commission > 0 THEN
      PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'quote_commission', p_quote_id::text);
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

CREATE OR REPLACE FUNCTION public.release_quote_atomic(p_actor_user_id uuid, p_quote_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE q public.service_quotes%ROWTYPE; v_provider uuid; v_res jsonb; v_got numeric;
BEGIN
  SELECT * INTO q FROM public.service_quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;
  IF q.client_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_CLIENT'; END IF;
  IF q.escrow_status = 'released' THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;
  IF NOT q.escrow OR q.escrow_status <> 'held' THEN RAISE EXCEPTION 'NOT_HELD'; END IF;

  SELECT ps.user_id INTO v_provider
  FROM public.professional_services ps
  WHERE ps.id = q.professional_service_id;

  -- Montant séquestré = total_amount COMPLET ; commission déjà prise au paiement.
  -- Garde : le prestataire DOIT être crédité, sinon ROLLBACK (pas de libération fantôme).
  v_res := public.credit_user_wallet_safe(v_provider, q.total_amount, 'GNF', 'quote_release', p_quote_id::text);
  v_got := COALESCE((v_res->>'credited')::numeric,0) + COALESCE((v_res->>'quarantined')::numeric,0);
  IF NOT COALESCE((v_res->>'skipped')::boolean, false) AND v_got <= 0 THEN RAISE EXCEPTION 'CREDIT_PRESTATAIRE_ECHOUE (%)', COALESCE(v_res->>'error','?'); END IF;

  UPDATE public.service_quotes SET escrow_status = 'released', status = 'completed', completed_at = now() WHERE id = p_quote_id;
  RETURN jsonb_build_object('success', true, 'released', q.total_amount);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.release_quote_atomic(uuid, uuid) TO service_role;

SELECT 'Devis durci : garde de crédit prestataire (direct + escrow) → ROLLBACK atomique si non crédité.' AS status;
