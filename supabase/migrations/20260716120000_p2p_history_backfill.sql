-- ============================================================================
-- BACKFILL (optionnel mais recommandé) : reconstruire l'historique OFFICIEL
-- wallet_transactions des transferts P2P déjà exécutés, perdus depuis l'origine.
--
-- CONSTAT (prod, 16/07/2026) : persistTransferHistory (backend Node) n'a JAMAIS
-- réussi son insert wallet_transactions :
--   • transfert même devise  → violation transaction_id NOT NULL (colonne
--     jamais fournie par le code) ;
--   • transfert inter-devises → enum sans 'international_transfer'.
-- Il existe 0 ligne transaction_type='transfer' dans toute la table, alors que
-- enhanced_transactions contient les transferts réels (source=backend-node,
-- metadata complètes : montants, devises, taux, frais, idempotency_key).
--
-- CE SCRIPT relit enhanced_transactions (source de vérité de ces transferts)
-- et émet les lignes wallet_transactions manquantes, datées à la date réelle.
-- Sémantique des montants (CHECK net_amount = amount - fee) :
--   amount = principal + frais (total débité expéditeur, SA devise),
--   fee    = frais expéditeur, net_amount = principal.
--
-- Idempotent : transaction_id déterministe ('p2pbf_' || id enhanced) +
-- NOT EXISTS sur l'idempotency_key + ON CONFLICT DO NOTHING.
-- ⚠️ À exécuter APRÈS 20260716110000 (la valeur d'enum doit être commitée).
-- Le dédup d'affichage du frontend s'appuie sur metadata.idempotency_key
-- (conservée ici) → pas de doublon visuel avec enhanced_transactions.
-- ============================================================================

INSERT INTO public.wallet_transactions
  (transaction_id, sender_wallet_id, receiver_wallet_id, sender_user_id, receiver_user_id,
   amount, fee, net_amount, currency, transaction_type, status, description, metadata, created_at)
SELECT
  left('p2pbf_' || et.id::text, 50),
  sw.id,
  rw.id,
  et.sender_id,
  et.receiver_id,
  round(coalesce((et.metadata->>'amount_sent')::numeric, et.amount)
        + coalesce((et.metadata->>'fee_amount')::numeric, 0), 2),
  round(coalesce((et.metadata->>'fee_amount')::numeric, 0), 2),
  round(coalesce((et.metadata->>'amount_sent')::numeric, et.amount), 2),
  upper(coalesce(et.metadata->>'sender_currency', et.currency, 'GNF')),
  CASE WHEN et.method = 'international_transfer'
       THEN 'international_transfer'::public.transaction_type
       ELSE 'transfer'::public.transaction_type END,
  'completed',
  coalesce(et.metadata->>'description', 'Transfert P2P'),
  coalesce(et.metadata, '{}'::jsonb) || jsonb_build_object('backfill', 'p2p-history-20260716'),
  et.created_at
FROM public.enhanced_transactions et
LEFT JOIN LATERAL (
  SELECT w.id FROM public.wallets w
  WHERE w.user_id = et.sender_id
    AND upper(w.currency) = upper(coalesce(et.metadata->>'sender_currency', et.currency, 'GNF'))
  ORDER BY w.id LIMIT 1
) sw ON true
LEFT JOIN LATERAL (
  SELECT w.id FROM public.wallets w
  WHERE w.user_id = et.receiver_id
    AND upper(w.currency) = upper(coalesce(et.metadata->>'receiver_currency', ''))
  ORDER BY w.id LIMIT 1
) rw ON true
WHERE et.method IN ('transfer', 'international_transfer')
  AND et.metadata->>'source' = 'backend-node'
  AND et.metadata->>'idempotency_key' IS NOT NULL
  AND et.status = 'completed'
  AND NOT EXISTS (
    SELECT 1 FROM public.wallet_transactions wt
    WHERE wt.transaction_id = left('p2pbf_' || et.id::text, 50)
       OR wt.metadata->>'idempotency_key' = et.metadata->>'idempotency_key'
  )
ON CONFLICT (transaction_id) DO NOTHING;
