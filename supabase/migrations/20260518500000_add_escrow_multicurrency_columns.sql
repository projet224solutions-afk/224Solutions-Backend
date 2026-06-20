-- ================================================================
-- MIGRATION escrow_transactions — colonnes multi-devises
--
-- But : stocker les informations de conversion dans l'escrow afin
--   qu'on puisse auditer combien a été débité du wallet acheteur
--   (buyer_debit_amount en sa devise) par rapport au montant original
--   (original_amount en devise vendeur).
--
-- Colonnes ajoutées :
--   original_amount      — montant total produit en devise vendeur
--   original_currency    — devise vendeur (ex : EUR)
--   buyer_debit_amount   — montant débité du wallet acheteur
--   buyer_debit_currency — devise du wallet acheteur (ex : GNF)
--   exchange_rate_used   — taux appliqué (NULL si même devise)
--   is_cross_currency    — true quand devise vendeur ≠ devise acheteur
-- ================================================================

ALTER TABLE public.escrow_transactions
  ADD COLUMN IF NOT EXISTS original_amount      NUMERIC(20, 4),
  ADD COLUMN IF NOT EXISTS original_currency    VARCHAR(3),
  ADD COLUMN IF NOT EXISTS buyer_debit_amount   NUMERIC(20, 4),
  ADD COLUMN IF NOT EXISTS buyer_debit_currency VARCHAR(3),
  ADD COLUMN IF NOT EXISTS exchange_rate_used   DECIMAL(20, 8),
  ADD COLUMN IF NOT EXISTS is_cross_currency    BOOLEAN DEFAULT false;

-- Index pour les requêtes PDG (transactions cross-currency)
CREATE INDEX IF NOT EXISTS idx_escrow_cross_currency
  ON public.escrow_transactions (is_cross_currency)
  WHERE is_cross_currency = true;

SELECT 'escrow_transactions — colonnes multi-devises ajoutées.' AS status;
