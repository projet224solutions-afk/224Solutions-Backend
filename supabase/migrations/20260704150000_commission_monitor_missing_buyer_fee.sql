-- ============================================================================
-- 👁️ SURVEILLANCE COMMISSIONS : contrôle « commande payée SANS frais acheteur »
-- ----------------------------------------------------------------------------
-- TROU DE COUVERTURE (audit du 04/07/2026) : commission_revenue_gap ne voit que
-- les frais DÉJÀ tracés (trace buyer_commission sans revenus_pdg). Si un bug
-- faisait passer des commandes wallet à commission ZÉRO (frais jamais facturés),
-- AUCUN contrôle ne sonnait — perte de revenus invisible.
--
-- NOUVEAU contrôle `order_missing_buyer_fee` : commandes du flux marketplace
-- wallet (= avec escrow) des 7 derniers jours, non annulées, SANS AUCUNE trace
-- `buyer_commission` — alors que les frais plateforme sont actifs
-- (system_settings.purchase_fee_percent > 0).
-- NB : si un vendeur a légitimement un taux 0 (plan particulier), le cas apparaît
-- dans le drill-down et le PDG l'acquitte — mieux qu'un angle mort.
--
-- Reprend À L'IDENTIQUE les 8 contrôles existants (20260608220000) + ajoute le 9e.
-- Non destructif, rejouable.
-- ============================================================================

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
  v_leak       int;  -- commission > base (frais) = fuite/manipulation
  v_neg        int;  -- commission ≤ 0 enregistrée
  v_dup        int;  -- doublons (agent_id, transaction_id) = brèche idempotence
  v_rapid      int;  -- rafale de commissions en 5 min = attaque/abus
  v_drift      int;  -- agent_wallets.balance ≠ somme des commissions loggées
  v_nofee      int;  -- 🆕 commande wallet payée SANS frais acheteur facturés
  v_fee_pct    numeric;
BEGIN
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

  SELECT count(*) INTO v_leak FROM public.agent_commissions_log
  WHERE transaction_amount IS NOT NULL
    AND COALESCE(transaction_amount, 0) > 0
    AND amount > transaction_amount
    AND created_at > now() - interval '7 days';

  SELECT count(*) INTO v_neg FROM public.agent_commissions_log
  WHERE COALESCE(amount, 0) <= 0
    AND created_at > now() - interval '7 days';

  SELECT COALESCE(count(*), 0) INTO v_dup FROM (
    SELECT 1 FROM public.agent_commissions_log
    WHERE transaction_id IS NOT NULL
      AND created_at > now() - interval '30 days'
    GROUP BY agent_id, transaction_id
    HAVING count(*) > 1
  ) d;

  SELECT count(*) INTO v_rapid FROM public.agent_commissions_log
  WHERE created_at > now() - interval '5 minutes';

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

  -- 🆕 9) Commande wallet (= avec escrow) SANS frais acheteur facturés, frais actifs.
  SELECT COALESCE(NULLIF(setting_value, '')::numeric, 0) INTO v_fee_pct
  FROM public.system_settings WHERE setting_key = 'purchase_fee_percent';
  IF COALESCE(v_fee_pct, 0) > 0 THEN
    SELECT count(*) INTO v_nofee
    FROM public.orders o
    WHERE o.created_at > now() - interval '7 days'
      AND o.status <> 'cancelled'
      AND COALESCE(o.total_amount, 0) > 0
      AND EXISTS (SELECT 1 FROM public.escrow_transactions e WHERE e.order_id = o.id)
      AND NOT EXISTS (
        SELECT 1 FROM public.wallet_transactions wt
        WHERE wt.transaction_type = 'commission'
          AND wt.metadata->>'source' = 'buyer_commission'
          AND wt.metadata->>'order_id' = o.id::text);
  ELSE
    v_nofee := 0; -- frais plateforme désactivés → aucune commande n'est censée en avoir
  END IF;

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','commission_revenue_gap','label','Commission acheteur prélevée mais non enregistrée (revenus PDG)','severity','high','count',v_gap,'observed',v_gap),
    jsonb_build_object('key','order_missing_buyer_fee','label','Commande wallet payée SANS frais acheteur (commission jamais facturée)','severity','high','count',v_nofee,'observed',v_nofee),
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

-- Vérification : le résultat doit contenir le nouveau contrôle.
SELECT CASE
  WHEN public.commission_monitor_report()::text LIKE '%order_missing_buyer_fee%'
    THEN '✅ commission_monitor_report : 9 contrôles, « order_missing_buyer_fee » actif'
  ELSE '❌ ÉCHEC : le nouveau contrôle est absent'
END AS status;
