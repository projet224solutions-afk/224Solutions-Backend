-- ================================================================
-- VÉRIFICATION COLONNES MANQUANTES — 2026-05-17
-- À exécuter dans Supabase Dashboard → SQL Editor
-- Ces ALTER TABLE sont IDEMPOTENTS (IF NOT EXISTS)
-- ================================================================

-- 1. orders.currency (nécessaire pour create_order_core Phase 2)
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS currency TEXT DEFAULT 'GNF';

-- 2. order_items.product_name (nécessaire pour create_order_core Phase 3)
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS product_name TEXT;

-- 3. Colonnes escrow_transactions (nécessaires pour Phase 5)
ALTER TABLE public.escrow_transactions
  ADD COLUMN IF NOT EXISTS buyer_id         UUID,
  ADD COLUMN IF NOT EXISTS seller_id        UUID,
  ADD COLUMN IF NOT EXISTS payer_id         UUID,
  ADD COLUMN IF NOT EXISTS receiver_id      UUID,
  ADD COLUMN IF NOT EXISTS payment_method   TEXT,
  ADD COLUMN IF NOT EXISTS commission_amount NUMERIC DEFAULT 0,
  ADD COLUMN IF NOT EXISTS auto_release_at  TIMESTAMPTZ;

-- Synchroniser auto_release_at depuis auto_release_date si existant
UPDATE public.escrow_transactions
SET auto_release_at = auto_release_date
WHERE auto_release_at IS NULL
  AND auto_release_date IS NOT NULL;

-- Vérification
SELECT
  'orders.currency'        AS colonne, EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='orders'       AND column_name='currency')       AS ok
UNION ALL SELECT
  'order_items.product_name',            EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='order_items'  AND column_name='product_name')
UNION ALL SELECT
  'escrow.buyer_id',                     EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='escrow_transactions' AND column_name='buyer_id')
UNION ALL SELECT
  'escrow.auto_release_at',              EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name='escrow_transactions' AND column_name='auto_release_at');
