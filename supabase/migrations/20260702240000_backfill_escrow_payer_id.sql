-- ============================================================================
-- BACKFILL escrow.payer_id / buyer_id = auth.uid() de l'ACHETEUR
-- ----------------------------------------------------------------------------
-- Les commandes NON-wallet (carte, mobile money, paiement à la livraison) créées
-- avant le fix ne passaient PAS p_buyer_user_id à create_order_core → l'escrow avait
-- payer_id = NULL et buyer_id = customers.id (id table clients), au lieu de l'auth.uid()
-- de l'acheteur exigé par les RLS et par les RPC de libération/remboursement.
--
-- Conséquences corrigées :
--   • confirm_delivery_and_release_escrow → « Non autorisé » (COALESCE(payer_id,buyer_id) ≠ userId)
--       => "Échec de la libération des fonds" à la confirmation de réception.
--   • refund_order_escrow → v_payer = customers.id (aucun wallet) → EXCEPTION
--       => "Échec du remboursement" à l'annulation.
--
-- On restaure payer_id ET buyer_id à l'auth.uid() réel via orders.customer_id → customers.user_id.
-- Idempotent : ne touche que les lignes où payer_id est NULL (les commandes wallet, déjà correctes,
-- ne sont pas modifiées). Rejouable sans effet.
-- ============================================================================

-- Aperçu AVANT (combien d'escrows fautifs)
SELECT count(*) AS escrows_a_corriger
FROM public.escrow_transactions e
JOIN public.orders o ON o.id = e.order_id
JOIN public.customers c ON c.id = o.customer_id
WHERE e.payer_id IS NULL AND c.user_id IS NOT NULL;

UPDATE public.escrow_transactions e
SET payer_id   = c.user_id,
    buyer_id   = c.user_id,
    updated_at = now()
FROM public.orders o
JOIN public.customers c ON c.id = o.customer_id
WHERE e.order_id = o.id
  AND e.payer_id IS NULL
  AND c.user_id IS NOT NULL;

-- Contrôle APRÈS (doit être 0)
SELECT count(*) AS escrows_restant_sans_payer
FROM public.escrow_transactions e
JOIN public.orders o ON o.id = e.order_id
JOIN public.customers c ON c.id = o.customer_id
WHERE e.payer_id IS NULL AND c.user_id IS NOT NULL;

SELECT 'Backfill escrow.payer_id/buyer_id = auth.uid() acheteur (commandes non-wallet).' AS status;
