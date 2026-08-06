-- ═══════════════════════════════════════════════════════════════════════════
-- INVARIANTS D'ARGENT post-tir (à exécuter APRÈS chaque scénario, sur STAGING).
-- Le test de charge n'est VALIDÉ que si TOUTES ces requêtes renvoient 0 (ou t).
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) Aucun doublon de référence de transaction wallet (une tx = une référence).
SELECT 'wallet_tx_ref_duplicates' AS invariant, count(*) AS violations FROM (
  SELECT wallet_tx_ref FROM public.provider_cash_sales
  WHERE wallet_tx_ref IS NOT NULL GROUP BY wallet_tx_ref HAVING count(*) > 1
) d;

-- 2) Idempotence caisse : aucune client_key en double (sous charge / rejeu).
SELECT 'cash_client_key_duplicates' AS invariant, count(*) AS violations FROM (
  SELECT provider_user_id, client_key FROM public.provider_cash_sales
  WHERE client_key IS NOT NULL GROUP BY 1,2 HAVING count(*) > 1
) d;

-- 3) Reçus séquentiels sans trou ni doublon (par prestataire/année).
SELECT 'receipt_gaps_or_dups' AS invariant, count(*) AS violations FROM (
  SELECT provider_user_id,
         count(*) AS n,
         max(split_part(receipt_number,'-',3)::int) - min(split_part(receipt_number,'-',3)::int) + 1 AS span
  FROM public.provider_cash_sales
  WHERE receipt_number LIKE 'REC-%'
  GROUP BY provider_user_id
  HAVING count(*) <> (max(split_part(receipt_number,'-',3)::int) - min(split_part(receipt_number,'-',3)::int) + 1)
) d;

-- 4) Aucun solde wallet négatif (sur-débit / course).
SELECT 'wallet_negative_balance' AS invariant, count(*) AS violations
FROM public.wallets WHERE balance < 0;

-- 5) Conservation : pour les transferts du tir, somme(débits) = somme(crédits+spread).
--    (Approche : chaque enhanced_transactions 'transfer' a un montant débité = crédité+quarantaine.)
SELECT 'transfer_conservation' AS invariant, count(*) AS violations
FROM public.enhanced_transactions
WHERE method = 'wallet' AND status = 'completed'
  AND created_at > now() - interval '1 hour'
  AND (metadata->>'credit_amount') IS NOT NULL
  AND round((metadata->>'credit_amount')::numeric, 2)
      < round((metadata->>'credited')::numeric, 2);  -- crédité ne peut dépasser le converti

-- 6) Revenu commission : chaque commande payée du tir a sa ligne revenus_pdg (ou 0 fee).
SELECT 'orders_without_commission' AS invariant, count(*) AS violations
FROM public.orders o
WHERE o.payment_status = 'paid'
  AND o.created_at > now() - interval '1 hour'
  AND (SELECT COALESCE(setting_value::numeric,0) FROM public.system_settings WHERE setting_key='purchase_fee_percent') > 0
  AND NOT EXISTS (SELECT 1 FROM public.revenus_pdg r
    WHERE r.source_type IN ('frais_achat_commande','frais_achat_marketplace')
      AND r.metadata->>'order_id' = o.id::text);
