-- ============================================================================
-- BLINDAGE commission agent + branchement Surveillance Plateforme
-- ----------------------------------------------------------------------------
-- credit_agent_commission est déjà ATOMIQUE (un seul bloc plpgsql = 1 transaction :
-- log + crédit agent_wallets + crédit wallet dépensable, tout ou rien) et IDEMPOTENT
-- (index unique idx_agent_commissions_log_unique_transaction sur (agent_id,
-- transaction_id)). Ce fichier ajoute la DÉTECTION TEMPS RÉEL des anomalies du flux
-- agent en étendant commission_monitor_report() — déjà branché dans MONITOR_DOMAINS
-- (surveillance 24/7 + onglet « Surveillance Plateforme »).
--
-- Garantit aussi (idempotent) la présence de l'index unique anti-doublon.
-- Non destructif, rejouable.
-- ============================================================================

-- Filet de sécurité : (re)crée l'index unique anti-doublon s'il manquait.
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_commissions_log_unique_transaction
  ON public.agent_commissions_log (agent_id, transaction_id)
  WHERE transaction_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.commission_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_gap        int;
  v_badrate    int;
  v_nonpos     int;
  -- nouveaux contrôles flux agent
  v_leak       int;  -- commission > base (frais) = fuite/manipulation
  v_neg        int;  -- commission ≤ 0 enregistrée
  v_dup        int;  -- doublons (agent_id, transaction_id) = brèche idempotence
  v_rapid      int;  -- rafale de commissions en 5 min = attaque/abus
  v_drift      int;  -- agent_wallets.balance ≠ somme des commissions loggées
BEGIN
  -- ===== contrôles existants =====
  SELECT count(*) INTO v_gap FROM public.wallet_transactions wt
  WHERE wt.transaction_type = 'commission'
    AND wt.metadata->>'source' = 'buyer_commission'
    AND wt.created_at > now() - interval '7 days'
    AND wt.metadata->>'order_id' IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.revenus_pdg r WHERE r.metadata->>'order_id' = wt.metadata->>'order_id');

  SELECT count(*) INTO v_badrate FROM public.agents_management
  WHERE is_active = true AND (
       COALESCE(commission_rate, 0) < 0 OR COALESCE(commission_rate, 0) > 100
    OR COALESCE(commission_agent_principal, 0) < 0 OR COALESCE(commission_agent_principal, 0) > 100
    OR COALESCE(commission_sous_agent, 0) < 0 OR COALESCE(commission_sous_agent, 0) > 100);

  SELECT count(*) INTO v_nonpos FROM public.revenus_pdg
  WHERE COALESCE(amount, 0) <= 0 AND created_at > now() - interval '7 days';

  -- ===== nouveaux contrôles : flux commission AGENT =====

  -- 1) FUITE : commission versée > base (transaction_amount). Ne doit JAMAIS arriver
  --    (la fonction plafonne à ≤100% de la base). Si >0 → bug/manipulation = grave.
  SELECT count(*) INTO v_leak FROM public.agent_commissions_log
  WHERE transaction_amount IS NOT NULL
    AND COALESCE(transaction_amount, 0) > 0
    AND amount > transaction_amount
    AND created_at > now() - interval '7 days';

  -- 2) Commission ≤ 0 enregistrée (incohérence).
  SELECT count(*) INTO v_neg FROM public.agent_commissions_log
  WHERE COALESCE(amount, 0) <= 0
    AND created_at > now() - interval '7 days';

  -- 3) DOUBLON : plusieurs lignes pour le même (agent_id, transaction_id) → brèche
  --    de l'idempotence (l'index unique aurait dû l'empêcher).
  SELECT COALESCE(count(*), 0) INTO v_dup FROM (
    SELECT 1 FROM public.agent_commissions_log
    WHERE transaction_id IS NOT NULL
      AND created_at > now() - interval '30 days'
    GROUP BY agent_id, transaction_id
    HAVING count(*) > 1
  ) d;

  -- 4) RAFALE : volume anormal de commissions en 5 min (attaque/abus).
  SELECT count(*) INTO v_rapid FROM public.agent_commissions_log
  WHERE created_at > now() - interval '5 minutes';

  -- 5) DÉRIVE WALLET : le wallet de suivi (agent_wallets GNF) doit égaler la somme des
  --    commissions loggées (il n'est jamais débité). Tout écart = crédit non tracé/bug.
  SELECT count(*) INTO v_drift FROM (
    SELECT aw.agent_id
    FROM public.agent_wallets aw
    LEFT JOIN (
      SELECT agent_id, COALESCE(sum(amount), 0) AS s
      FROM public.agent_commissions_log GROUP BY agent_id
    ) l ON l.agent_id = aw.agent_id
    WHERE COALESCE(aw.currency_type, aw.currency, 'GNF') = 'GNF'
      AND ABS(COALESCE(aw.balance, 0) - COALESCE(l.s, 0)) > 1
  ) d;

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','commission_revenue_gap','label','Commission acheteur prélevée mais non enregistrée (revenus PDG)','severity','high','count',v_gap,'observed',v_gap),
    jsonb_build_object('key','agent_bad_rate','label','Taux de commission agent hors limites (0–100%)','severity','medium','count',v_badrate,'observed',v_badrate),
    jsonb_build_object('key','revenue_nonpositive','label','Revenu PDG nul ou négatif','severity','medium','count',v_nonpos,'observed',v_nonpos),
    jsonb_build_object('key','agent_commission_leak','label','Commission agent > base (fuite/manipulation)','severity','critical','count',v_leak,'observed',v_leak),
    jsonb_build_object('key','agent_commission_nonpositive','label','Commission agent ≤ 0 enregistrée','severity','medium','count',v_neg,'observed',v_neg),
    jsonb_build_object('key','agent_commission_duplicate','label','Doublon commission (agent, transaction) — brèche idempotence','severity','high','count',v_dup,'observed',v_dup),
    jsonb_build_object('key','agent_commission_rapid','label','Rafale de commissions agent (5 min) — possible attaque/abus','severity',CASE WHEN v_rapid > 50 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 50 THEN v_rapid ELSE 0 END,'observed',v_rapid),
    jsonb_build_object('key','agent_wallet_drift','label','Wallet agent ≠ somme des commissions loggées (crédit non tracé)','severity','high','count',v_drift,'observed',v_drift)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.commission_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.commission_monitor_report() TO service_role;

SELECT 'commission_monitor_report() étendu : 5 contrôles flux agent ajoutés.' AS status;
