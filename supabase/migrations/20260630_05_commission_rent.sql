-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 4 (flux LOYER) — commission agent sur le paiement de loyer en ligne.
-- ════════════════════════════════════════════════════════════════════════════
-- pay_rent_atomic crédite DÉJÀ le PDG de sa commission (v_commission, L128) comme
-- le marketplace → il suffit d'ajouter credit_agent_commission (qui en débite 20%,
-- Étape 1) → net 80% PDG / 20% agents. PAS apply_platform_commission ici (re-
-- créditerait le PDG = double). v_pdg résolu via pdg_management = même wallet que
-- débite l'Étape 1. Loyer payé wallet (wallet_debit_internal) = toujours EN LIGNE.
-- Fonction reproduite À L'IDENTIQUE + l'appel commission (non bloquant) après le
-- crédit PDG.
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.pay_rent_atomic(p_actor_user_id uuid, p_lease_id uuid, p_period text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE l public.rental_leases%ROWTYPE; v_owner uuid; v_rate numeric; v_commission numeric; v_pdg uuid; v_receipt text; v_exists uuid;
BEGIN
  SELECT * INTO l FROM public.rental_leases WHERE id = p_lease_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LEASE_NOT_FOUND'; END IF;
  IF l.tenant_user_id <> p_actor_user_id THEN RAISE EXCEPTION 'NOT_TENANT'; END IF;
  IF l.status <> 'active' THEN RAISE EXCEPTION 'LEASE_NOT_ACTIVE'; END IF;

  SELECT id INTO v_exists FROM public.rent_payments WHERE lease_id = p_lease_id AND period_label = p_period;
  IF v_exists IS NOT NULL THEN RETURN jsonb_build_object('success', true, 'already', true); END IF;

  SELECT owner_id INTO v_owner FROM public.properties WHERE id = l.property_id;
  PERFORM public.wallet_debit_internal(p_actor_user_id, l.monthly_rent, 'Loyer ' || p_period, 'rent-' || p_lease_id::text || '-' || p_period);
  v_rate := public.resolve_service_commission_rate(v_owner, 'location', 0);
  v_commission := round(l.monthly_rent * v_rate / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;
  PERFORM public.credit_user_wallet_safe(v_owner, l.monthly_rent - v_commission, 'GNF', 'rent_payment', p_lease_id::text);
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'rent_commission', p_lease_id::text);
  END IF;

  -- ✅ COMMISSION AGENT (le loyer = wallet, toujours en ligne). Le PDG vient d'être
  -- crédité de v_commission ; credit_agent_commission en débite 20% (Étape 1) → net
  -- 80% PDG / 20% agents. NON BLOQUANT + idempotent (par lease_id).
  IF v_commission > 0 THEN
    BEGIN
      PERFORM public.credit_agent_commission(p_actor_user_id, v_commission, 'rent', p_lease_id,
        jsonb_build_object('currency', 'GNF', 'flow', 'rent', 'lease_id', p_lease_id, 'period', p_period));
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'commission agent loyer non appliquée (lease %): %', p_lease_id, SQLERRM;
    END;
  END IF;

  v_receipt := 'QUIT-' || p_period || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
  INSERT INTO public.rent_payments (lease_id, period_label, amount, receipt_code)
  VALUES (p_lease_id, p_period, l.monthly_rent, v_receipt);
  RETURN jsonb_build_object('success', true, 'receipt', v_receipt);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.pay_rent_atomic(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.pay_rent_atomic(uuid, uuid, text) TO service_role;

DO $$ BEGIN RAISE NOTICE '✅ pay_rent_atomic : commission agent branchée (loyer en ligne)'; END $$;

COMMIT;
