-- ============================================================================
-- 🔧 SUPPRESSION de l'ANCIENNE surcharge create_order_core (13 args) — fuite escrow.
--
-- Constat : deux surcharges create_order_core coexistent en base :
--   • ANCIENNE (13 args, SANS p_buyer_fee_amount / p_seller_commission_amount) → crée
--     l'escrow avec le MONTANT TOTAL (frais inclus) et SANS commission vendeur = la fuite.
--   • NOUVELLE (16 args, avec frais acheteur→PDG + commission vendeur) = correcte.
-- Le backend déployé (ancien) appelle la 13 args → chemin buggé encore atteignable.
--
-- Fix : on DROP la 13 args. Les appels en 13 arguments basculent alors automatiquement
-- sur la 16 args (les 3 derniers paramètres ont des valeurs par défaut) → escrow = SOUS-TOTAL
-- (plus jamais le total). Idempotent. La 16 args (correcte) reste en place, intacte.
--
-- ⚠️ Reste recommandé : redéployer le backend pour qu'il passe p_seller_commission_amount
--    (5%) et p_buyer_fee_amount explicitement (sinon commission = fallback 2,5%, frais = 0).
-- ============================================================================

DROP FUNCTION IF EXISTS public.create_order_core(
  text, uuid, uuid, uuid, text, text, jsonb, text, jsonb, integer, uuid, numeric, text
);

SELECT 'Ancienne surcharge create_order_core (13 args, escrow=total sans commission) supprimée. Seule la 16 args correcte subsiste.' AS status;
