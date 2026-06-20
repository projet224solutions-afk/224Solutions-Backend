-- =================================================================
-- MIGRATION: Système de prix multi-devises Marketplace
-- Date: 2026-05-12
-- Objectif: Ajouter les colonnes devise aux produits, vendeurs et commandes.
--           Réutilise le système FX existant (currency_exchange_rates + getInternalFxRate).
--           N'ajoute pas de nouveau système de taux.
-- =================================================================

-- ─────────────────────────────────────────────────────────────────
-- 1. TABLE vendors: devise locale verrouillée
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE vendors
  ADD COLUMN IF NOT EXISTS shop_currency     VARCHAR(3),
  ADD COLUMN IF NOT EXISTS currency_locked   BOOLEAN  DEFAULT true,
  ADD COLUMN IF NOT EXISTS seller_country_code VARCHAR(2);

-- Remplir shop_currency depuis country existant
UPDATE vendors
SET
  seller_country_code = CASE
    WHEN LENGTH(COALESCE(country,'')) = 2 THEN UPPER(country)
    WHEN LOWER(country) = 'guinée'               THEN 'GN'
    WHEN LOWER(country) LIKE 'sénégal%'          THEN 'SN'
    WHEN LOWER(country) LIKE 'côte%'             THEN 'CI'
    WHEN LOWER(country) = 'mali'                 THEN 'ML'
    WHEN LOWER(country) = 'cameroun'             THEN 'CM'
    WHEN LOWER(country) = 'france'               THEN 'FR'
    WHEN LOWER(country) = 'nigeria'              THEN 'NG'
    WHEN LOWER(country) = 'ghana'                THEN 'GH'
    WHEN LOWER(country) = 'maroc'                THEN 'MA'
    WHEN LOWER(country) IN ('usa','états-unis','etats-unis') THEN 'US'
    WHEN LOWER(country) = 'canada'               THEN 'CA'
    WHEN LOWER(country) IN ('uk','royaume-uni')  THEN 'GB'
    ELSE NULL
  END,
  shop_currency = CASE
    WHEN LENGTH(COALESCE(country,'')) = 2 THEN
      CASE UPPER(country)
        WHEN 'GN' THEN 'GNF'
        WHEN 'SN' THEN 'XOF' WHEN 'CI' THEN 'XOF' WHEN 'ML' THEN 'XOF'
        WHEN 'BF' THEN 'XOF' WHEN 'NE' THEN 'XOF' WHEN 'TG' THEN 'XOF'
        WHEN 'BJ' THEN 'XOF' WHEN 'GW' THEN 'XOF'
        WHEN 'CM' THEN 'XAF' WHEN 'GA' THEN 'XAF' WHEN 'CG' THEN 'XAF'
        WHEN 'TD' THEN 'XAF' WHEN 'CF' THEN 'XAF' WHEN 'GQ' THEN 'XAF'
        WHEN 'FR' THEN 'EUR' WHEN 'DE' THEN 'EUR' WHEN 'IT' THEN 'EUR'
        WHEN 'ES' THEN 'EUR' WHEN 'PT' THEN 'EUR' WHEN 'BE' THEN 'EUR'
        WHEN 'NL' THEN 'EUR' WHEN 'LU' THEN 'EUR'
        WHEN 'US' THEN 'USD'
        WHEN 'GB' THEN 'GBP'
        WHEN 'CA' THEN 'CAD'
        WHEN 'MA' THEN 'MAD'
        WHEN 'NG' THEN 'NGN'
        WHEN 'GH' THEN 'GHS'
        WHEN 'KE' THEN 'KES'
        WHEN 'ZA' THEN 'ZAR'
        ELSE 'GNF'
      END
    WHEN LOWER(country) = 'guinée'               THEN 'GNF'
    WHEN LOWER(country) LIKE 'sénégal%'          THEN 'XOF'
    WHEN LOWER(country) LIKE 'côte%'             THEN 'XOF'
    WHEN LOWER(country) = 'mali'                 THEN 'XOF'
    WHEN LOWER(country) = 'cameroun'             THEN 'XAF'
    WHEN LOWER(country) = 'france'               THEN 'EUR'
    WHEN LOWER(country) = 'nigeria'              THEN 'NGN'
    WHEN LOWER(country) = 'ghana'                THEN 'GHS'
    WHEN LOWER(country) = 'maroc'                THEN 'MAD'
    WHEN LOWER(country) IN ('usa','états-unis','etats-unis') THEN 'USD'
    WHEN LOWER(country) = 'canada'               THEN 'CAD'
    WHEN LOWER(country) IN ('uk','royaume-uni')  THEN 'GBP'
    ELSE 'GNF'
  END,
  currency_locked = true
WHERE shop_currency IS NULL;

-- Défaut pour vendeurs sans pays connu
UPDATE vendors
SET shop_currency = 'GNF', currency_locked = true
WHERE shop_currency IS NULL;

-- ─────────────────────────────────────────────────────────────────
-- 2. TABLE products: prix original avec devise
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE products
  ADD COLUMN IF NOT EXISTS original_price_currency  VARCHAR(3),
  ADD COLUMN IF NOT EXISTS seller_currency          VARCHAR(3),
  ADD COLUMN IF NOT EXISTS seller_country_code      VARCHAR(2),
  ADD COLUMN IF NOT EXISTS needs_currency_review    BOOLEAN DEFAULT false;

-- Remplir depuis la boutique du vendeur
UPDATE products p
SET
  original_price_currency = COALESCE(v.shop_currency, 'GNF'),
  seller_currency         = COALESCE(v.shop_currency, 'GNF'),
  seller_country_code     = v.seller_country_code,
  needs_currency_review   = (v.shop_currency IS NULL OR v.country IS NULL OR v.country = '')
FROM vendors v
WHERE p.vendor_id = v.id
  AND p.original_price_currency IS NULL;

-- Produits orphelins (vendeur inconnu)
UPDATE products
SET
  original_price_currency = 'GNF',
  needs_currency_review   = true
WHERE original_price_currency IS NULL;

-- Index pour filtrer les produits à revoir
CREATE INDEX IF NOT EXISTS idx_products_needs_review
  ON products(needs_currency_review) WHERE needs_currency_review = true;

-- Index pour recherches par devise vendeur
CREATE INDEX IF NOT EXISTS idx_products_original_currency
  ON products(original_price_currency);

CREATE INDEX IF NOT EXISTS idx_vendors_shop_currency
  ON vendors(shop_currency);

-- ─────────────────────────────────────────────────────────────────
-- 3. TABLE orders: suivi financier multi-devises
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE orders
  ADD COLUMN IF NOT EXISTS buyer_currency        VARCHAR(3),
  ADD COLUMN IF NOT EXISTS seller_currency       VARCHAR(3),
  ADD COLUMN IF NOT EXISTS original_currency     VARCHAR(3),
  ADD COLUMN IF NOT EXISTS total_original_amount DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS total_paid_amount     DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS paid_currency         VARCHAR(3),
  ADD COLUMN IF NOT EXISTS exchange_rate_used    DECIMAL(20,8),
  ADD COLUMN IF NOT EXISTS exchange_rate_source  TEXT,
  ADD COLUMN IF NOT EXISTS rate_fetched_at       TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS rate_locked_at        TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS is_cross_currency     BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS platform_fee_percent  DECIMAL(5,2),
  ADD COLUMN IF NOT EXISTS platform_fee_amount   DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS platform_fee_currency VARCHAR(3),
  ADD COLUMN IF NOT EXISTS seller_net_amount     DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS seller_net_currency   VARCHAR(3);

-- Migrer les commandes existantes (combler les nouvelles colonnes)
UPDATE orders o
SET
  original_currency     = COALESCE(v.shop_currency, 'GNF'),
  seller_currency       = COALESCE(v.shop_currency, 'GNF'),
  buyer_currency        = COALESCE(v.shop_currency, 'GNF'),
  paid_currency         = COALESCE(v.shop_currency, 'GNF'),
  total_original_amount = o.total_amount,
  total_paid_amount     = o.total_amount,
  exchange_rate_used    = 1,
  exchange_rate_source  = 'migration-same-currency',
  is_cross_currency     = false,
  platform_fee_percent  = 5,
  platform_fee_amount   = ROUND(o.total_amount * 0.05, 2),
  platform_fee_currency = COALESCE(v.shop_currency, 'GNF'),
  seller_net_amount     = ROUND(o.total_amount * 0.95, 2),
  seller_net_currency   = COALESCE(v.shop_currency, 'GNF')
FROM vendors v
WHERE o.vendor_id = v.id
  AND o.buyer_currency IS NULL;

-- Commandes sans vendeur (fallback)
UPDATE orders
SET
  original_currency     = 'GNF',
  seller_currency       = 'GNF',
  buyer_currency        = 'GNF',
  paid_currency         = 'GNF',
  total_original_amount = total_amount,
  total_paid_amount     = total_amount,
  exchange_rate_used    = 1,
  exchange_rate_source  = 'migration-fallback',
  is_cross_currency     = false,
  platform_fee_percent  = 5,
  platform_fee_amount   = ROUND(total_amount * 0.05, 2),
  platform_fee_currency = 'GNF',
  seller_net_amount     = ROUND(total_amount * 0.95, 2),
  seller_net_currency   = 'GNF'
WHERE buyer_currency IS NULL;

-- ─────────────────────────────────────────────────────────────────
-- 4. TABLE order_items: devise de l'article
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE order_items
  ADD COLUMN IF NOT EXISTS original_currency    VARCHAR(3),
  ADD COLUMN IF NOT EXISTS buyer_currency       VARCHAR(3),
  ADD COLUMN IF NOT EXISTS unit_price_original  DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS unit_price_converted DECIMAL(20,4),
  ADD COLUMN IF NOT EXISTS exchange_rate_used   DECIMAL(20,8);

-- Remplir depuis la commande parente
UPDATE order_items oi
SET
  original_currency    = o.original_currency,
  buyer_currency       = o.buyer_currency,
  unit_price_original  = oi.unit_price,
  unit_price_converted = oi.unit_price,
  exchange_rate_used   = 1
FROM orders o
WHERE oi.order_id = o.id
  AND oi.original_currency IS NULL;

-- ─────────────────────────────────────────────────────────────────
-- 5. TABLE checkout_rate_locks: verrouillage du taux au checkout
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS checkout_rate_locks (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  buyer_id        UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  vendor_id       UUID REFERENCES vendors(id) ON DELETE SET NULL,
  from_currency   VARCHAR(3) NOT NULL,
  to_currency     VARCHAR(3) NOT NULL,
  original_amount DECIMAL(20,4) NOT NULL,
  converted_amount DECIMAL(20,4) NOT NULL,
  exchange_rate   DECIMAL(20,8) NOT NULL,
  rate_source     TEXT,
  rate_fetched_at TIMESTAMPTZ,
  locked_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at      TIMESTAMPTZ NOT NULL,
  order_id        UUID REFERENCES orders(id) ON DELETE SET NULL,
  status          TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','expired','used','cancelled')),
  created_at      TIMESTAMPTZ DEFAULT NOW(),
  updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rate_locks_buyer
  ON checkout_rate_locks(buyer_id, status);
CREATE INDEX IF NOT EXISTS idx_rate_locks_expires
  ON checkout_rate_locks(expires_at) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_rate_locks_order
  ON checkout_rate_locks(order_id) WHERE order_id IS NOT NULL;

-- RLS pour checkout_rate_locks
ALTER TABLE checkout_rate_locks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users see own rate locks" ON checkout_rate_locks;
CREATE POLICY "Users see own rate locks"
ON checkout_rate_locks FOR SELECT
USING (auth.uid() = buyer_id);

-- ─────────────────────────────────────────────────────────────────
-- 6. FONCTION: get_vendor_currency(vendor_id)
--    Retourne la devise d'un vendeur depuis la DB
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_vendor_currency(p_vendor_id UUID)
RETURNS VARCHAR(3) AS $$
DECLARE
  v_currency VARCHAR(3);
BEGIN
  SELECT COALESCE(shop_currency, get_currency_for_country(COALESCE(seller_country_code, country, 'GN')), 'GNF')
  INTO v_currency
  FROM vendors
  WHERE id = p_vendor_id AND is_active = true;

  RETURN COALESCE(v_currency, 'GNF');
END;
$$ LANGUAGE plpgsql STABLE;

-- ─────────────────────────────────────────────────────────────────
-- 7. FONCTION: get_buyer_currency(user_id)
--    Retourne la devise de l'acheteur depuis son wallet/profil
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_buyer_currency(p_user_id UUID)
RETURNS VARCHAR(3) AS $$
DECLARE
  v_currency VARCHAR(3);
BEGIN
  -- Priorité 1: wallet actif
  SELECT currency INTO v_currency
  FROM wallets
  WHERE user_id = p_user_id
    AND wallet_status = 'active'
    AND (is_blocked = false OR is_blocked IS NULL)
  LIMIT 1;

  IF v_currency IS NOT NULL THEN RETURN v_currency; END IF;

  -- Priorité 2: profil (detected_currency ou pays)
  SELECT COALESCE(
    NULLIF(detected_currency, ''),
    get_currency_for_country(COALESCE(NULLIF(detected_country,''), country, 'GN')),
    'GNF'
  )
  INTO v_currency
  FROM profiles
  WHERE id = p_user_id;

  RETURN COALESCE(v_currency, 'GNF');
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_buyer_currency(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_vendor_currency(UUID) TO authenticated;

-- ─────────────────────────────────────────────────────────────────
-- 8. TRIGGER: auto-remplir seller_currency sur products à l'insertion
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync_product_seller_currency()
RETURNS TRIGGER AS $$
DECLARE
  v_shop_currency VARCHAR(3);
  v_country_code  VARCHAR(2);
BEGIN
  SELECT shop_currency, seller_country_code
  INTO v_shop_currency, v_country_code
  FROM vendors
  WHERE id = NEW.vendor_id;

  NEW.original_price_currency := COALESCE(v_shop_currency, 'GNF');
  NEW.seller_currency         := COALESCE(v_shop_currency, 'GNF');
  NEW.seller_country_code     := v_country_code;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_product_seller_currency ON products;
CREATE TRIGGER trg_sync_product_seller_currency
  BEFORE INSERT ON products
  FOR EACH ROW
  EXECUTE FUNCTION sync_product_seller_currency();

-- ─────────────────────────────────────────────────────────────────
-- 9. TRIGGER: auto-remplir shop_currency sur vendors à l'insertion
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync_vendor_shop_currency()
RETURNS TRIGGER AS $$
DECLARE
  v_country_code VARCHAR(2);
  v_currency     VARCHAR(3);
BEGIN
  -- Normaliser le code pays
  v_country_code := CASE
    WHEN LENGTH(COALESCE(NEW.country,'')) = 2 THEN UPPER(NEW.country)
    ELSE NULL
  END;

  -- Calculer la devise depuis detected_country du profil du vendeur
  IF v_country_code IS NULL AND NEW.user_id IS NOT NULL THEN
    SELECT UPPER(COALESCE(detected_country, ''))
    INTO v_country_code
    FROM profiles
    WHERE id = NEW.user_id
    LIMIT 1;
    IF v_country_code = '' THEN v_country_code := NULL; END IF;
  END IF;

  v_currency := get_currency_for_country(COALESCE(v_country_code, 'GN'));

  NEW.seller_country_code := v_country_code;
  NEW.shop_currency       := COALESCE(v_currency, 'GNF');
  NEW.currency_locked     := true;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_vendor_shop_currency ON vendors;
CREATE TRIGGER trg_sync_vendor_shop_currency
  BEFORE INSERT ON vendors
  FOR EACH ROW
  EXECUTE FUNCTION sync_vendor_shop_currency();

-- ─────────────────────────────────────────────────────────────────
-- 10. RPC: get_product_display_price(product_id, buyer_user_id)
--     Utilisée par le frontend pour afficher le prix converti
--     NB: ne fait PAS de conversion FX (côté DB les taux sont live)
--     Retourne les métadonnées de prix pour que le frontend puisse
--     déclencher la conversion via usePriceConverter.
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_product_display_price(
  p_product_id  UUID,
  p_buyer_id    UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_product RECORD;
  v_buyer_currency VARCHAR(3);
BEGIN
  SELECT p.id, p.price, p.compare_price,
         COALESCE(p.original_price_currency, v.shop_currency, 'GNF') AS original_currency,
         COALESCE(p.seller_currency, v.shop_currency, 'GNF')         AS seller_currency,
         v.id AS vendor_id, v.country AS vendor_country,
         COALESCE(v.shop_currency, 'GNF')                            AS vendor_currency
  INTO v_product
  FROM products p
  JOIN vendors  v ON v.id = p.vendor_id
  WHERE p.id = p_product_id AND p.is_active = true;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Produit introuvable');
  END IF;

  -- Devise acheteur (optionnel)
  IF p_buyer_id IS NOT NULL THEN
    v_buyer_currency := get_buyer_currency(p_buyer_id);
  ELSE
    v_buyer_currency := v_product.original_currency;
  END IF;

  RETURN jsonb_build_object(
    'success',             true,
    'product_id',          v_product.id,
    'original_amount',     v_product.price,
    'original_currency',   v_product.original_currency,
    'seller_currency',     v_product.seller_currency,
    'compare_price',       v_product.compare_price,
    'buyer_currency',      v_buyer_currency,
    'is_cross_currency',   (v_product.original_currency != v_buyer_currency),
    'vendor_id',           v_product.vendor_id
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION get_product_display_price(UUID, UUID) TO authenticated, anon;

-- Log
DO $$
BEGIN
  RAISE NOTICE '✅ Migration marketplace multi-devises appliquée avec succès';
END $$;
