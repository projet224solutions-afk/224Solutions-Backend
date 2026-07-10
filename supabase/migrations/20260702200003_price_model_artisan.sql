-- ============================================================================
-- MODÈLE DE PRIX UNIFORME — ARTISAN (l'artisan reçoit son montant COMPLET)
-- ----------------------------------------------------------------------------
-- ⚠️ CONSTAT : le fix bcb8522 (collision idempotence solde + commission agent,
-- fichier 20260630_08) N'EST PAS sur main. La version déployée (20260614240000)
-- a DEUX bugs : (a) amputation artisan (v_net), (b) crédits artisan+PDG idempotents
-- par p_intervention_id → le SOLDE était bloqué (même clé que l'acompte).
-- Cette migration produit la version DÉFINITIVE = les 2 fixes bcb8522 + modèle prix :
--   • Débit client = montant + commission (au lieu du montant seul).
--   • Crédit artisan = montant COMPLET (fin de v_net).
--   • Crédits artisan + PDG idempotents par p_idempotency_key (DISTINCT acompte/solde) → fin du blocage.
--   • Commission agent (débite 20% du PDG, Étape 1), ref md5(p_idempotency_key), NON bloquante.
--   • Commission PDG inchangée (base v_commission). Invariant : débit == artisan + PDG.
-- Le helper est partagé par les 2 phases (acompte + solde) ; les RPC appelantes
-- (pay_artisan_deposit_atomic + solde) passent une clé DISTINCTE par phase → inchangées.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.artisan_settle_payment_internal(
  p_intervention_id uuid, p_client uuid, p_artisan uuid, p_service_type text,
  p_amount numeric, p_idempotency_key text, p_label text
) RETURNS numeric
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rate numeric; v_commission numeric; v_pdg uuid;
BEGIN
  IF COALESCE(p_amount,0) <= 0 THEN RETURN 0; END IF;

  SELECT COALESCE(commission_rate, 5) INTO v_rate FROM public.service_types WHERE code = p_service_type;
  v_commission := round(p_amount * COALESCE(v_rate,5) / 100.0);
  SELECT user_id INTO v_pdg FROM public.pdg_management WHERE is_active = true LIMIT 1;

  -- 1) Débit client = montant + COMMISSION (payée par le client EN PLUS). Idempotence
  --    forte par p_idempotency_key (distincte acompte/solde) → vérif solde sur le total.
  PERFORM public.wallet_debit_internal(p_client, p_amount + v_commission, p_label, p_idempotency_key);
  -- 2) Crédit artisan du montant COMPLET. Idempotence par p_idempotency_key (fix bcb8522 :
  --    plus p_intervention_id qui bloquait le solde).
  PERFORM public.credit_user_wallet_safe(p_artisan, p_amount, 'GNF', 'artisan_payment', p_idempotency_key);
  -- 3) Commission plateforme au PDG (clé = p_idempotency_key).
  IF v_pdg IS NOT NULL AND v_commission > 0 THEN
    PERFORM public.credit_user_wallet_safe(v_pdg, v_commission, 'GNF', 'artisan_commission', p_idempotency_key);
    -- Commission agent : débite 20% du PDG (Étape 1), ref distincte par phase, NON bloquante.
    BEGIN
      PERFORM public.credit_agent_commission(p_artisan, v_commission, 'artisan', md5(p_idempotency_key)::uuid,
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

SELECT 'Modèle prix artisan : artisan reçoit le montant complet (acompte+solde), commission payée par le client, idempotence par phase (fix bcb8522 intégré).' AS status;
