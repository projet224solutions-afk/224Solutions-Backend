-- 🧹 DISMISS SÛR de l'alerte « Libérations non converties » (non_converted_releases)
-- ----------------------------------------------------------------------------------
-- Marque les lignes historiques fautives (Edge 'confirm-delivery' supprimée :
-- transaction_type='payment' + description LIKE 'Libération escrow%') avec
-- metadata->>'reversed'='true'. La RPC escrow_monitor_report (migration
-- 20260702230000) EXCLUT ces lignes → le compteur tombe à 0 → l'alerte s'AUTO-RÉSOUT
-- au cycle suivant.
--
-- ✅ NE TOUCHE À AUCUN SOLDE (contrairement à l'ancien cleanup-escrow-non-converted.sql,
--    réservé aux données de TEST — ne PAS l'exécuter en prod).
-- ✅ IDEMPOTENT : ne re-tague pas ce qui l'est déjà.
-- ⚠️ À FAIRE D'ABORD : vérifier (PART A) que ces libérations sont bien réconciliées /
--    sans préjudice vendeur. Ce script DISMISS l'alerte ; il ne rembourse rien. Si une
--    ligne représente un vrai sur-crédit à récupérer, traite-la séparément (débit ciblé).

-- ─────────────────── PART A : INSPECTION (lecture seule) ───────────────────
-- Chaque ligne fautive + le solde ACTUEL du wallet destinataire, pour décision.
SELECT wt.id,
       wt.receiver_user_id,
       wt.amount,
       wt.currency,
       wt.description,
       wt.created_at,
       (wt.metadata->>'reversed') AS already_dismissed,
       w.balance   AS receiver_balance,
       w.currency  AS receiver_wallet_currency
FROM public.wallet_transactions wt
LEFT JOIN public.wallets w ON w.user_id = wt.receiver_user_id
WHERE wt.transaction_type = 'payment'
  AND wt.description LIKE 'Libération escrow%'
ORDER BY wt.created_at DESC;

-- ─────────────────── PART B : DISMISS (tag seul, transaction sûre) ───────────────────
-- ROLLBACK par défaut. Vérifie PART A ci-dessus, puis remplace ROLLBACK par COMMIT.
BEGIN;

  UPDATE public.wallet_transactions
  SET metadata = COALESCE(metadata, '{}'::jsonb)
                 || jsonb_build_object(
                      'reversed', true,
                      'reason', 'non_converted_escrow_release_dismissed',
                      'dismissed_at', now()
                    )
  WHERE transaction_type = 'payment'
    AND description LIKE 'Libération escrow%'
    AND COALESCE(metadata->>'reversed', '') <> 'true';   -- idempotent : saute le déjà-tagué

  -- Contrôle : combien restent NON taguées (doit être 0 après ce UPDATE)
  SELECT count(*) AS restantes_non_taguees
  FROM public.wallet_transactions
  WHERE transaction_type = 'payment'
    AND description LIKE 'Libération escrow%'
    AND COALESCE(metadata->>'reversed', '') <> 'true';

ROLLBACK; -- ⚠️ Vérifie « restantes_non_taguees = 0 » ci-dessus, puis remplace par COMMIT pour appliquer.
