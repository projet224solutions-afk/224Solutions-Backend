-- ================================================================
-- COLONNES FINANCIÈRES MULTI-DEVISES POUR LA TABLE ORDERS
-- Idempotent : ADD COLUMN IF NOT EXISTS
--
-- Ces colonnes sont remplies par le backend après create_order_core.
-- Si elles sont absentes, le backend loggue un warning (non-fatal).
-- Cette migration garantit leur existence pour la prochaine run.
-- ================================================================

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS buyer_currency        VARCHAR(3),
  ADD COLUMN IF NOT EXISTS seller_currency       VARCHAR(3),
  ADD COLUMN IF NOT EXISTS original_currency     VARCHAR(3),
  ADD COLUMN IF NOT EXISTS total_original_amount DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS total_paid_amount     DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS paid_currency         VARCHAR(3),
  ADD COLUMN IF NOT EXISTS exchange_rate_used    DECIMAL(20,8),
  ADD COLUMN IF NOT EXISTS exchange_rate_source  TEXT,
  ADD COLUMN IF NOT EXISTS is_cross_currency     BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS platform_fee_percent  DECIMAL(5,2),
  ADD COLUMN IF NOT EXISTS platform_fee_amount   DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS platform_fee_currency VARCHAR(3),
  ADD COLUMN IF NOT EXISTS seller_net_amount     DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS seller_net_currency   VARCHAR(3);

SELECT 'orders: colonnes financières multi-devises vérifiées.' AS status;
