-- ============================================================================
-- SURVEILLANCE PLATEFORME — (B) auto-clear des alertes escrow corrigées
--                          + (PERF) index pour éviter les seq scans / timeouts 8s
-- ----------------------------------------------------------------------------
-- À APPLIQUER dans le SQL Editor Supabase. Additif et idempotent (IF NOT EXISTS).
-- Aucune donnée modifiée hors le CREATE OR REPLACE de la RPC de surveillance.
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- (B) escrow_monitor_report : ne plus compter les libérations non-converties DÉJÀ
--     RÉVERSÉES (tag metadata->>'reversed'='true', posé par le script de nettoyage
--     scripts/cleanup-escrow-non-converted.sql). Ainsi, dès que l'anomalie est
--     corrigée, le count tombe à 0 et l'alerte est AUTO-RÉSOLUE au cycle suivant
--     (syncDomainAlerts passe status='resolved' quand count=0). Le reste des 8
--     contrôles est IDENTIQUE à la version courante (20260621010000).
-- ─────────────────────────────────────────────────────────────────────────────
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
  -- ✚ exclut les lignes déjà réversées (corrigées) → l'alerte disparaît après nettoyage
  SELECT count(*) INTO v_non_converted FROM public.wallet_transactions
  WHERE transaction_type = 'payment' AND description LIKE 'Libération escrow%'
    AND COALESCE(metadata->>'reversed', '') <> 'true'
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
    AND source_type IN ('official_html', 'official_fixed_parity')
    AND COALESCE(retrieved_at, timestamptz '2000-01-01') < now() - interval '24 hours';
  SELECT count(*) INTO v_rapid FROM public.wallet_transactions
  WHERE transaction_type IN ('escrow_release', 'refund')
    AND created_at > now() - interval '5 minutes';
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
      jsonb_build_object('key','stale_rates','label','Taux BCRG officiels périmés > 24h (conversion à risque)','severity','high','count',v_stale_rates,'observed',v_stale_rates),
      jsonb_build_object('key','rapid_ops','label','Opérations escrow rapides (5 min) — possible attaque','severity',CASE WHEN v_rapid > 30 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 30 THEN v_rapid ELSE 0 END,'observed',v_rapid),
      jsonb_build_object('key','escrow_amount_mismatch','label','Escrow ACTIF > montant produit (commission incluse → fuite)','severity','critical','count',v_escrow_mismatch,'observed',v_escrow_mismatch)
    )
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- (PERF) Index pour supprimer les seq scans des RPC de surveillance (cause des
--        timeouts 8s → 500 intermittent). Purement additifs. NB : sur de TRÈS
--        grosses tables, préférer CREATE INDEX CONCURRENTLY exécuté séparément
--        (hors transaction) pour ne pas verrouiller en écriture.
-- ─────────────────────────────────────────────────────────────────────────────

-- commission_monitor_report / commission_revenue_gap : NOT EXISTS corrélé sur
-- revenus_pdg.metadata->>'order_id' (sinon seq scan de revenus_pdg par ligne).
CREATE INDEX IF NOT EXISTS idx_revenus_pdg_meta_order_id
  ON public.revenus_pdg ((metadata->>'order_id'));

-- order_monitor_report + pos_monitor_report / negative_stock : index PARTIEL minuscule
-- (n'indexe que les anomalies, quasi vide en régime sain) → count instantané.
CREATE INDEX IF NOT EXISTS idx_products_negative_stock
  ON public.products (id) WHERE COALESCE(stock_quantity, 0) < 0;

-- money_integrity_report / escrow_released_no_commission : escrows libérés sans commission.
CREATE INDEX IF NOT EXISTS idx_escrow_released_nocomm
  ON public.escrow_transactions (created_at)
  WHERE status = 'released' AND COALESCE(commission_amount, 0) = 0;

-- syncDomainAlerts : lookup de dédup (module, status='active', metadata->>'alert_key') par check.
CREATE INDEX IF NOT EXISTS idx_system_alerts_module_status_key
  ON public.system_alerts (module, status, (metadata->>'alert_key'));

-- runPlatformMonitors : lecture finale .in(module).order(created_at desc).limit(60).
CREATE INDEX IF NOT EXISTS idx_system_alerts_module_created
  ON public.system_alerts (module, created_at DESC);

SELECT 'Surveillance : auto-clear non-converted (reversed) + 5 index de perf.' AS status;
