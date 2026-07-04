-- ============================================================================
-- ✅ « MARQUER COMME TRAITÉ » : les contrôles historiques deviennent acquittables
-- ----------------------------------------------------------------------------
-- Demande PDG (04/07/2026) : la pastille d'un domaine doit rester VERTE tant que
-- tout fonctionne, et ne passer ORANGE que pour de VRAIS problèmes en cours. Or
-- certains contrôles constatent des FAITS HISTORIQUES exacts (ex. commande de
-- l'ancien flux sans trace de frais, hausse de solde d'une session de correction) :
-- une fois l'argent régularisé, le compteur restait > 0 jusqu'à la sortie de la
-- fenêtre de 7 jours → orange trompeur qui noie les vrais bugs.
--
-- MÉCANISME : le PDG clique « Marquer comme traité » dans le drill-down →
-- INSERT dans money_integrity_acknowledged (check_key, ref_id) [table existante,
-- déjà utilisée par escrow_released_zero_credit] → les contrôles ci-dessous
-- EXCLUENT les cas acquittés → compteur retombe → pastille verte → l'alerte
-- part automatiquement en Historique (résolue) au cycle suivant.
--
-- Contrôles rendus acquittables (faits historiques uniquement) :
--   • commission_monitor_report.order_missing_buyer_fee (ref = orders.id)
--   • wallet_provenance_report.untraced_increase       (ref = wallet_balance_audit.id)
-- Les états VIVANTS (plafond dépassé, quarantaines) restent NON acquittables :
-- ils se résolvent par une vraie action, pas un clic.
-- Non destructif, rejouable.
-- ============================================================================

-- 1) ── commission_monitor_report : order_missing_buyer_fee exclut les cas traités ──
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
  v_leak       int;
  v_neg        int;
  v_dup        int;
  v_rapid      int;
  v_drift      int;
  v_nofee      int;
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

  -- Commande wallet (= avec escrow) SANS frais acheteur facturés, frais actifs,
  -- HORS cas « marqués traités » par le PDG (money_integrity_acknowledged).
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
          AND wt.metadata->>'order_id' = o.id::text)
      AND NOT EXISTS (
        SELECT 1 FROM public.money_integrity_acknowledged k
        WHERE k.check_key = 'order_missing_buyer_fee' AND k.ref_id = o.id::text);
  ELSE
    v_nofee := 0;
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

-- 2) ── wallet_provenance_report : untraced_increase exclut les cas traités ──
CREATE OR REPLACE FUNCTION public.wallet_provenance_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_untraced   int;
  v_over_cap   int;
  v_q_pending  int;
  v_q_stale    int;
BEGIN
  -- Hausse de solde (7j) sans transaction de crédit correspondante (±10 min),
  -- HORS cas « marqués traités » par le PDG.
  SELECT count(*) INTO v_untraced FROM public.wallet_balance_audit a
  WHERE a.delta > 0
    AND a.changed_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE wt.receiver_user_id = a.user_id
        AND wt.created_at BETWEEN a.changed_at - interval '10 minutes'
                              AND a.changed_at + interval '10 minutes')
    AND NOT EXISTS (
      SELECT 1 FROM public.money_integrity_acknowledged k
      WHERE k.check_key = 'untraced_increase' AND k.ref_id = a.id::text);

  SELECT count(*) INTO v_over_cap FROM public.wallets w
  WHERE public.wallet_effective_cap(w.user_id) IS NOT NULL
    AND public.convert_to_gnf(COALESCE(w.balance, 0), w.currency)
        > public.wallet_effective_cap(w.user_id) + 1;

  SELECT count(*) INTO v_q_pending FROM public.wallet_quarantined_funds WHERE status = 'pending';

  SELECT count(*) INTO v_q_stale FROM public.wallet_quarantined_funds
  WHERE status = 'pending' AND created_at < now() - interval '7 days';

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','untraced_increase','label','Hausse de solde sans transaction (argent injecté hors circuit)','severity','critical','count',v_untraced,'observed',v_untraced),
    jsonb_build_object('key','wallet_over_cap','label','Wallet au-dessus de son plafond de détention (à examiner)','severity','high','count',v_over_cap,'observed',v_over_cap),
    jsonb_build_object('key','quarantine_pending','label','Fonds en quarantaine en attente de décision PDG','severity','high','count',v_q_pending,'observed',v_q_pending),
    jsonb_build_object('key','quarantine_stale','label','Quarantaine non traitée depuis > 7 jours','severity','medium','count',v_q_stale,'observed',v_q_stale)
  ));
END;
$$;

REVOKE ALL ON FUNCTION public.wallet_provenance_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.wallet_provenance_report() TO service_role;

-- 3) ── Vérification ─────────────────────────────────────────────────────────
SELECT CASE
  WHEN pg_get_functiondef(p.oid) LIKE '%money_integrity_acknowledged%'
    THEN '✅ ' || p.proname || ' : acquittement branché'
  ELSE '❌ ' || p.proname || ' : acquittement ABSENT'
END AS status
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('commission_monitor_report', 'wallet_provenance_report')
ORDER BY p.proname;
