-- ============================================================================
-- 🧹 NETTOYAGE SURVEILLANCE — n'alerter que sur l'ACTIONNABLE + résoudre le bruit historique.
--
-- Contexte : après le correctif de la fuite escrow (20260617470000/490000 appliqués le 21/06),
-- l'alerte escrow_amount_mismatch comptait encore 18 escrows HISTORIQUES déjà released/refunded
-- (créés avant le fix) → non corrigeables, donc bruit. + 3 ventes à crédit de TEST échues.
--
-- Fix :
--   1) escrow_amount_mismatch ne compte plus que les escrows ENCORE 'held' (= corrigeables) ;
--   2) ventes à crédit de test marquées payées ;
--   3) alertes system_alerts correspondantes passées à 'resolved' (le cycle 24/7 confirmera count=0).
-- ============================================================================

-- ───────────── 1) escrow_monitor_report : mismatch sur escrows ACTIFS uniquement ─────────────
CREATE OR REPLACE FUNCTION public.escrow_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_non_converted   int;
  v_net_mismatch    int;
  v_cur_mismatch    int;
  v_no_ledger       int;
  v_held_overdue    int;
  v_stale_rates     int;
  v_rapid           int;
  v_escrow_mismatch int;
BEGIN
  SELECT count(*) INTO v_non_converted FROM public.wallet_transactions
  WHERE transaction_type = 'payment' AND description LIKE 'Libération escrow%'
    AND created_at > now() - interval '7 days';
  SELECT count(*) INTO v_net_mismatch FROM public.wallet_transactions
  WHERE COALESCE(net_amount, 0) <> COALESCE(amount, 0) - COALESCE(fee, 0)
    AND created_at > now() - interval '7 days';
  SELECT count(*) INTO v_cur_mismatch FROM public.wallet_transactions wt
  JOIN public.escrow_transactions e ON e.id::text = wt.metadata->>'escrow_id'
  WHERE wt.transaction_type = 'escrow_release'
    AND wt.currency <> COALESCE(e.currency, 'GNF')
    AND wt.created_at > now() - interval '7 days';
  SELECT count(*) INTO v_no_ledger FROM public.escrow_transactions e
  WHERE e.status = 'released' AND e.released_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE wt.transaction_type = 'escrow_release'
        AND (wt.reference_id = e.id::text OR wt.metadata->>'escrow_id' = e.id::text));
  SELECT count(*) INTO v_held_overdue FROM public.escrow_transactions
  WHERE status = 'held' AND auto_release_at IS NOT NULL
    AND auto_release_at < now() - interval '14 days';
  SELECT count(*) INTO v_stale_rates FROM public.currency_exchange_rates
  WHERE is_active = true AND (from_currency = 'GNF' OR to_currency = 'GNF')
    AND COALESCE(retrieved_at, timestamptz '2000-01-01') < now() - interval '24 hours';
  SELECT count(*) INTO v_rapid FROM public.wallet_transactions
  WHERE transaction_type IN ('escrow_release', 'refund')
    AND created_at > now() - interval '5 minutes';

  -- ✚ NE compte que les escrows ENCORE 'held' : un escrow déjà released/refunded au mauvais montant
  -- est du passé NON corrigeable (bruit). L'alerte ne doit pointer que ce qui est actionnable
  -- (un escrow actif sur-doté = régression à corriger AVANT libération).
  SELECT count(*) INTO v_escrow_mismatch FROM public.escrow_transactions e
  JOIN public.orders o ON o.id = e.order_id
  WHERE o.subtotal IS NOT NULL AND e.amount > o.subtotal + 0.01
    AND e.status = 'held'
    AND e.created_at > now() - interval '30 days';

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','non_converted_releases','label','Libérations non converties (Edge cassée)','severity','critical','count',v_non_converted,'observed',v_non_converted),
      jsonb_build_object('key','net_mismatch','label','Incohérence net ≠ montant − frais','severity','critical','count',v_net_mismatch,'observed',v_net_mismatch),
      jsonb_build_object('key','currency_mismatch','label','Devise de libération ≠ devise escrow','severity','high','count',v_cur_mismatch,'observed',v_cur_mismatch),
      jsonb_build_object('key','released_no_ledger','label','Escrow libéré sans trace d''historique','severity','high','count',v_no_ledger,'observed',v_no_ledger),
      jsonb_build_object('key','held_overdue','label','Escrow bloqué > 14j (cron en panne ?)','severity','medium','count',v_held_overdue,'observed',v_held_overdue),
      jsonb_build_object('key','stale_rates','label','Taux BCRG périmés > 24h (conversion à risque)','severity','high','count',v_stale_rates,'observed',v_stale_rates),
      jsonb_build_object('key','rapid_ops','label','Opérations escrow rapides (5 min) — possible attaque','severity',CASE WHEN v_rapid > 30 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 30 THEN v_rapid ELSE 0 END,'observed',v_rapid),
      jsonb_build_object('key','escrow_amount_mismatch','label','Escrow ACTIF > montant produit (commission incluse → fuite)','severity','critical','count',v_escrow_mismatch,'observed',v_escrow_mismatch)
    )
  );
END;
$$;

-- ───────────── 2) Ventes à crédit de TEST marquées payées (échues impayées de démo) ─────────────
UPDATE public.vendor_credit_sales
SET status = 'paid', paid_amount = total, remaining_amount = 0, updated_at = now()
WHERE order_number IN ('CR-ML654PYX', 'CR-ML6VH8Q1', 'CR-ML6VHWGR')
  AND status = 'pending';

-- ───────────── 3) Résoudre immédiatement les alertes devenues sans objet ─────────────
UPDATE public.system_alerts
SET status = 'resolved', resolved_at = now()
WHERE status = 'active'
  AND metadata->>'alert_key' IN ('escrow_amount_mismatch', 'pos_credit_overdue');

SELECT 'Surveillance nettoyée : escrow_amount_mismatch=escrows held only, ventes test payées, alertes résolues.' AS status;
