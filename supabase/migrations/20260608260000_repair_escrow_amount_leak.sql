-- ============================================================================
-- Réparation + affinage de la fuite escrow (escrow_amount_mismatch)
-- ----------------------------------------------------------------------------
-- CONTEXTE (investigation 2026-06-08) : d'anciens escrows ont été créés avec
--   amount = subtotal + commission acheteur (ex. 60000 → 61200), car l'ancienne
--   version du backend /orders écrasait escrow.amount avec le montant CHARGÉ
--   (produit + frais) au lieu du subtotal. À la libération, le vendeur est alors
--   sur-payé de la commission acheteur = FUITE (la plateforme paie plus qu'elle
--   n'a encaissé). Le bug est corrigé côté backend (orders.routes.ts : escrow.amount
--   = result.subtotal) et la RPC create_order_core insère déjà amount = subtotal.
--
-- CETTE MIGRATION :
--   1. RÉPARE les escrows encore NON libérés (held/pending) dont amount > subtotal
--      → remet amount = subtotal pour qu'ils libèrent le bon montant au vendeur.
--      (Les escrows déjà released/refunded ne sont pas touchés : l'argent est sorti,
--       c'est de l'historique ; on ne réécrit pas le passé comptable.)
--   2. AFFINE escrow_amount_mismatch pour ne compter que les escrows NON libérés
--      gonflés (= le seul cas actionnable / une vraie régression). Après réparation
--      et déploiement du fix, ce capteur reste à 0 ; un nouvel escrow gonflé (encore
--      held) ressortirait immédiatement.
-- Non destructif, rejouable.
-- ============================================================================

-- ───────────── 1. Réparation des escrows non libérés gonflés ─────────────
UPDATE public.escrow_transactions e
SET amount = o.subtotal, updated_at = now()
FROM public.orders o
WHERE o.id = e.order_id
  AND e.status IN ('held', 'pending')
  AND o.subtotal IS NOT NULL
  AND e.amount > o.subtotal + 0.01;

-- ───────────── 2. escrow_monitor_report : capteur affiné (held/pending) ─────────────
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

  -- AFFINÉ : escrow ENCORE NON LIBÉRÉ (held/pending) dont amount > subtotal produit.
  -- C'est le seul cas actionnable (on peut encore éviter le sur-paiement du vendeur).
  -- Les escrows déjà released/refunded gonflés sont de l'historique (argent sorti) → non comptés.
  SELECT count(*) INTO v_escrow_mismatch FROM public.escrow_transactions e
  JOIN public.orders o ON o.id = e.order_id
  WHERE e.status IN ('held', 'pending')
    AND o.subtotal IS NOT NULL AND e.amount > o.subtotal + 0.01;

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
      jsonb_build_object('key','escrow_amount_mismatch','label','Escrow non libéré > montant produit (commission incluse → fuite vendeur)','severity','critical','count',v_escrow_mismatch,'observed',v_escrow_mismatch)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.escrow_monitor_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.escrow_monitor_report() TO service_role;

SELECT 'Escrows non libérés gonflés réparés + escrow_amount_mismatch affiné (held/pending).' AS status;
