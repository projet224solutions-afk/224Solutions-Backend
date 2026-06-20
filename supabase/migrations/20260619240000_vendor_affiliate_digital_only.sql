-- ============================================================================
-- 🤝 AFFILIATION VENDEUR — RESTRICTION AUX PRODUITS NUMÉRIQUES.
--
-- Correction : le programme d'affiliation (type Amazon Associates) ne concerne QUE les
-- produits NUMÉRIQUES (`digital_products`), jamais les produits physiques (`products`).
-- On déplace donc l'activation/taux vers digital_products et on repointe les FK des
-- tables d'attribution/commission vers digital_products (tables encore vides → sans risque).
-- ============================================================================

-- 1) Activation par produit NUMÉRIQUE + taux de commission.
ALTER TABLE public.digital_products ADD COLUMN IF NOT EXISTS affiliate_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.digital_products ADD COLUMN IF NOT EXISTS affiliate_commission_rate numeric NOT NULL DEFAULT 0
  CHECK (affiliate_commission_rate >= 0 AND affiliate_commission_rate <= 90);

-- 2) Nettoyage : retirer ces colonnes des produits PHYSIQUES (ajoutées par erreur).
ALTER TABLE public.products DROP COLUMN IF EXISTS affiliate_enabled;
ALTER TABLE public.products DROP COLUMN IF EXISTS affiliate_commission_rate;

-- 3) Repointer la FK product_id → digital_products (au lieu de products).
ALTER TABLE public.affiliate_clicks DROP CONSTRAINT IF EXISTS affiliate_clicks_product_id_fkey;
ALTER TABLE public.affiliate_clicks
  ADD CONSTRAINT affiliate_clicks_product_id_fkey
  FOREIGN KEY (product_id) REFERENCES public.digital_products(id) ON DELETE CASCADE;

ALTER TABLE public.affiliate_commissions DROP CONSTRAINT IF EXISTS affiliate_commissions_product_id_fkey;
ALTER TABLE public.affiliate_commissions
  ADD CONSTRAINT affiliate_commissions_product_id_fkey
  FOREIGN KEY (product_id) REFERENCES public.digital_products(id) ON DELETE CASCADE;

SELECT 'Affiliation restreinte aux produits numériques : digital_products.affiliate_*, FK clics/commissions repointées.' AS status;
