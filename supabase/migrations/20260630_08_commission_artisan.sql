-- ════════════════════════════════════════════════════════════════════════════
-- ÉTAPE 4 (flux ARTISAN) — fix collision idempotence + commission agent.
-- ════════════════════════════════════════════════════════════════════════════
-- 🔴 BUG PRÉ-EXISTANT corrigé : artisan_settle_payment_internal créditait l'artisan
-- (L38) ET le PDG (L41) avec la clé d'idempotence = p_intervention_id, IDENTIQUE pour
-- l'acompte ET le solde. Le débit client (L36) utilise p_idempotency_key (distinct) →
-- le client était débité 2 fois mais l'artisan/PDG n'étaient crédités QUE de l'acompte
-- (le solde bloqué par wallet_credit_idempotency). Argent bloqué.
-- FIX : crédits artisan + PDG idempotents par p_idempotency_key (distinct par phase).
--
-- + COMMISSION AGENT : le PDG est crédité v_commission → credit_agent_commission en
-- débite 20% (Étape 1) → net 80/20. Ref distincte par phase = md5(p_idempotency_key)::uuid.
-- Non bloquant. Seul le helper change ; les RPC acompte/solde sont inchangés.
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.artisan_settle_payment_internal(
  p_intervention_id uuid, p_client uuid, p_artisan uuid, p_service_type text,
  p_amount numeric, p_idempotency_key text, p_label text
) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric; v_commission numeric; v_net numeric; v_pdg uuid;
BEGIN
  IF COALESCE(p_amount,0) <= 0 THEN RETURN 0; END IF;

  SELECT COALESCE(commission_rate, 5) INTO v_rate FROM public.service_types WHERE code = p_service_type;
  v_commission := round(p_amount * COALESCE(v_rate,5) / 100.0);
  v_net        := p_amount - v_commission;
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- 1) Débit client (idempotence forte : 1 paiement par clé) → ROLLBACK si solde/blocage.
  PERFORM public.wallet_debit_internal(p_client, p_amount, p_label, p_idempotency_key);
  -- 2) Crédit net à l'artisan. ✅ FIX : clé = p_idempotency_key (distincte acompte/solde),
  --    plus p_intervention_id (qui bloquait le solde).
  PERFORM public.credit_user_wallet_safe(p_artisan, v_net, 'GNF', 'artisan_payment', p_idempotency_key);
  -- 3) Commission plateforme au PDG. ✅ FIX : clé = p_idempotency_key.
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'artisan_commission', p_idempotency_key);
    -- ✅ COMMISSION AGENT : débite 20% du PDG (Étape 1) → net 80/20. Ref distincte par
    --    phase (md5 de la clé), non bloquant.
    BEGIN
      PERFORM public.credit_agent_commission(p_client, v_commission, 'artisan', md5(p_idempotency_key)::uuid,
        jsonb_build_object('currency', 'GNF', 'flow', 'artisan', 'intervention_id', p_intervention_id, 'phase', p_idempotency_key));
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'commission agent artisan non appliquée (% / %): %', p_intervention_id, p_idempotency_key, SQLERRM;
    END;
  END IF;

  UPDATE public.artisan_interventions
    SET amount_paid = amount_paid + p_amount, commission_total = commission_total + v_commission
    WHERE id = p_intervention_id;

  RETURN v_commission;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.artisan_settle_payment_internal(uuid, uuid, uuid, text, numeric, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.artisan_settle_payment_internal(uuid, uuid, uuid, text, numeric, text, text) TO service_role;

DO $$ BEGIN RAISE NOTICE '✅ artisan : collision idempotence corrigée + commission agent branchée'; END $$;

COMMIT;
