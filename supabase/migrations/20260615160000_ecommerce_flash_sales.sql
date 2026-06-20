-- ============================================================================
-- E-COMMERCE (PHASE 3) — FLASH SALES (stock temps réel, urgence Pinduoduo).
-- ----------------------------------------------------------------------------
-- Le vendeur alloue un stock à prix promo pour une durée. Le stock restant est lu en
-- temps réel par les clients (Supabase Realtime). RLS : vendeur gère les siennes,
-- lecture publique des ventes flash actives. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.flash_sales (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_user_id  uuid NOT NULL REFERENCES auth.users(id),
  product_id      uuid,
  product_name    text NOT NULL,
  sale_price      numeric(12,2) NOT NULL,
  stock_allocated integer NOT NULL DEFAULT 0,
  stock_sold      integer NOT NULL DEFAULT 0,
  ends_at         timestamptz NOT NULL DEFAULT (now() + interval '6 hours'),
  is_active       boolean NOT NULL DEFAULT true,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_flash_sales_vendor ON public.flash_sales (vendor_user_id, is_active);

ALTER TABLE public.flash_sales ENABLE ROW LEVEL SECURITY;

-- Le vendeur gère SES ventes flash.
DROP POLICY IF EXISTS flash_sales_owner ON public.flash_sales;
CREATE POLICY flash_sales_owner ON public.flash_sales
  FOR ALL TO authenticated USING (vendor_user_id = auth.uid()) WITH CHECK (vendor_user_id = auth.uid());

-- Lecture publique des ventes flash actives (affichage + stock temps réel).
DROP POLICY IF EXISTS flash_sales_public_read ON public.flash_sales;
CREATE POLICY flash_sales_public_read ON public.flash_sales
  FOR SELECT USING (is_active = true);

SELECT 'Flash sales créées (RLS owner + lecture publique active).' AS status;
