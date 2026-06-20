-- 🩺 SURVEILLANCE ESCROW & CONVERSION — RPC de détection d'anomalies (lecture seule, SECURITY DEFINER)
--
-- Calcule en une passe les anomalies du système escrow + conversion. Le backend l'appelle (cycle 60s
-- + à la demande depuis l'interface PDG), crée/résout des alertes dans system_alerts.
-- Renvoie : { generated_at, checks: [{ key, label, severity, count, observed }] }.
--   count = nombre d'anomalies (0 = sain) ; observed = valeur brute observée (pour rapid_ops).

CREATE OR REPLACE FUNCTION public.escrow_monitor_report()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_non_converted int;
  v_net_mismatch  int;
  v_cur_mismatch  int;
  v_no_ledger     int;
  v_held_overdue  int;
  v_stale_rates   int;
  v_rapid         int;
BEGIN
  -- 1. Libérations NON converties (signature de l'Edge Function cassée : type=payment + "Libération escrow")
  SELECT count(*) INTO v_non_converted FROM public.wallet_transactions
  WHERE transaction_type = 'payment' AND description LIKE 'Libération escrow%'
    AND created_at > now() - interval '7 days';

  -- 2. Incohérence net_amount <> amount - fee (la contrainte devrait l'empêcher → double-contrôle)
  SELECT count(*) INTO v_net_mismatch FROM public.wallet_transactions
  WHERE COALESCE(net_amount, 0) <> COALESCE(amount, 0) - COALESCE(fee, 0)
    AND created_at > now() - interval '7 days';

  -- 3. Libération escrow dont la devise de la ligne ≠ devise de l'escrow
  SELECT count(*) INTO v_cur_mismatch FROM public.wallet_transactions wt
  JOIN public.escrow_transactions e ON e.id::text = wt.metadata->>'escrow_id'
  WHERE wt.transaction_type = 'escrow_release'
    AND wt.currency <> COALESCE(e.currency, 'GNF')
    AND wt.created_at > now() - interval '7 days';

  -- 4. Escrow 'released' sans ligne d'historique de libération (libération sans trace)
  SELECT count(*) INTO v_no_ledger FROM public.escrow_transactions e
  WHERE e.status = 'released' AND e.released_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE wt.transaction_type = 'escrow_release'
        AND (wt.reference_id = e.id::text OR wt.metadata->>'escrow_id' = e.id::text));

  -- 5. Escrow 'held' échu depuis > 14 jours (cron auto-release en panne ?)
  SELECT count(*) INTO v_held_overdue FROM public.escrow_transactions
  WHERE status = 'held' AND auto_release_at IS NOT NULL
    AND auto_release_at < now() - interval '14 days';

  -- 6. Taux BCRG (GNF) périmés > 24h → conversions à risque
  SELECT count(*) INTO v_stale_rates FROM public.currency_exchange_rates
  WHERE is_active = true AND (from_currency = 'GNF' OR to_currency = 'GNF')
    AND COALESCE(retrieved_at, timestamptz '2000-01-01') < now() - interval '24 hours';

  -- 7. Opérations escrow/refund très rapides (5 min) — possible attaque / runaway
  SELECT count(*) INTO v_rapid FROM public.wallet_transactions
  WHERE transaction_type IN ('escrow_release', 'refund')
    AND created_at > now() - interval '5 minutes';

  RETURN jsonb_build_object(
    'generated_at', now(),
    'checks', jsonb_build_array(
      jsonb_build_object('key','non_converted_releases','label','Libérations non converties (Edge cassée)','severity','critical','count',v_non_converted,'observed',v_non_converted),
      jsonb_build_object('key','net_mismatch','label','Incohérence net ≠ montant − frais','severity','critical','count',v_net_mismatch,'observed',v_net_mismatch),
      jsonb_build_object('key','currency_mismatch','label','Devise de libération ≠ devise escrow','severity','high','count',v_cur_mismatch,'observed',v_cur_mismatch),
      jsonb_build_object('key','released_no_ledger','label','Escrow libéré sans trace d''historique','severity','high','count',v_no_ledger,'observed',v_no_ledger),
      jsonb_build_object('key','held_overdue','label','Escrow bloqué > 14j (cron en panne ?)','severity','medium','count',v_held_overdue,'observed',v_held_overdue),
      jsonb_build_object('key','stale_rates','label','Taux BCRG périmés > 24h (conversion à risque)','severity','high','count',v_stale_rates,'observed',v_stale_rates),
      jsonb_build_object('key','rapid_ops','label','Opérations escrow rapides (5 min) — possible attaque','severity',CASE WHEN v_rapid > 30 THEN 'high' ELSE 'low' END,'count',CASE WHEN v_rapid > 30 THEN v_rapid ELSE 0 END,'observed',v_rapid)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.escrow_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.escrow_monitor_report() TO service_role;

SELECT 'escrow_monitor_report() créée — 7 contrôles d''anomalies escrow/conversion.' AS status;
