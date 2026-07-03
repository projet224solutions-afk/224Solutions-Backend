-- 🩺 SURVEILLANCE ESCROW : le contrôle « libéré sans trace » reconnaît les traces HÉRITÉES
-- ─────────────────────────────────────────────────────────────────────────────
-- CONTEXTE (audit escrow 74b744a5 / commande ORD-MQZN4VEY-0KHW) : l'ancienne Edge
-- confirm-delivery (supprimée) écrivait la ligne d'historique de libération en
-- transaction_type='payment' (description « Libération escrow … ») au lieu de
-- 'escrow_release'. Le vendeur A donc été payé et la trace EXISTE — mais le contrôle
-- released_no_ledger ne cherchait que le type 'escrow_release' → fausse alerte
-- « Escrow libéré sans trace d'historique » pendant 7 jours pour chaque cas hérité.
--
-- FIX : le NOT EXISTS accepte les DEUX formes de trace. Résultat : count=0 au prochain
-- cycle → syncDomainAlerts passe l'alerte en 'resolved' → elle apparaît dans la section
-- « Historique des alertes résolues » du panneau Surveillance (les corrigés VONT dans
-- l'historique, ils ne squattent plus les actives).
-- Le reste de la fonction est STRICTEMENT identique à 20260702230000.

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
  -- ✚ FIX : une libération est TRACÉE si l'on trouve SOIT la trace moderne
  -- ('escrow_release'), SOIT la trace héritée de l'ancienne Edge ('payment' +
  -- description « Libération escrow … ») — vendeur payé, historique présent.
  SELECT count(*) INTO v_no_ledger FROM public.escrow_transactions e
  WHERE e.status = 'released' AND e.released_at > now() - interval '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM public.wallet_transactions wt
      WHERE (wt.reference_id = e.id::text OR wt.metadata->>'escrow_id' = e.id::text)
        AND (
          wt.transaction_type = 'escrow_release'
          OR (wt.transaction_type = 'payment' AND wt.description LIKE 'Libération escrow%')
        ));
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

SELECT 'released_no_ledger reconnaît les traces héritées (payment + Libération escrow%) — les cas corrigés partent en historique.' AS status;
