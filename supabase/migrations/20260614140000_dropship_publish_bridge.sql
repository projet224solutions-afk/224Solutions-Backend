-- ============================================================================
-- DROPSHIPPING — Phase 1 : BRIDGE « produit importé → produit VENDABLE »
-- ----------------------------------------------------------------------------
-- PROBLÈME : `saveProduct` écrivait dans `dropship_products` (is_published=false)
-- SANS créer de ligne dans le catalogue `products` → le client ne pouvait pas
-- acheter le produit importé (contrairement à Shopify où l'import = produit boutique).
--
-- ICI : un RPC ATOMIQUE crée/met à jour un produit `products` (miroir boutique) lié
-- au `dropship_product`, et bascule `is_published`. Idempotent (re-publier met à jour
-- le même produit). SECURITY DEFINER + contrôle de propriété (vendeur) à l'intérieur.
-- Rejouable.
-- ============================================================================

-- Lien dropship → produit catalogue publié (1 source ↔ 1 miroir).
ALTER TABLE public.dropship_products
  ADD COLUMN IF NOT EXISTS published_product_id uuid REFERENCES public.products(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_dropship_products_published
  ON public.dropship_products (published_product_id);

-- ─────────────────────────────────────────────────────────────────────────
-- Résout le vendors.id à partir du dropship_products.vendor_id, qui peut être
-- SOIT un vendors.id SOIT un user_id (selon la voie d'import). Retourne NULL si rien.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_vendor_id(p_ref uuid)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(
    (SELECT id FROM public.vendors WHERE id = p_ref),
    (SELECT id FROM public.vendors WHERE user_id = p_ref ORDER BY created_at LIMIT 1)
  );
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- PUBLIER : crée/maj le produit catalogue miroir et lie le dropship_product.
-- p_actor_user_id : l'utilisateur qui déclenche (contrôle de propriété), NULL = service.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.publish_dropship_product(
  p_dropship_id uuid,
  p_actor_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  dp            public.dropship_products%ROWTYPE;
  v_vendor_id   uuid;
  v_vendor_user uuid;
  v_currency    text;
  v_name        text;
  v_price       numeric;
  v_product_id  uuid;
  v_action      text;
  v_is_admin    boolean;
BEGIN
  SELECT * INTO dp FROM public.dropship_products WHERE id = p_dropship_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DROPSHIP_PRODUCT_NOT_FOUND'; END IF;

  v_vendor_id := public.resolve_vendor_id(dp.vendor_id);
  IF v_vendor_id IS NULL THEN RAISE EXCEPTION 'VENDOR_NOT_RESOLVED'; END IF;
  SELECT user_id INTO v_vendor_user FROM public.vendors WHERE id = v_vendor_id;

  -- Contrôle de propriété : l'acteur doit être le vendeur OU un admin/pdg.
  IF p_actor_user_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = p_actor_user_id AND lower(COALESCE(role,'')) IN ('admin','pdg','ceo')
    ) INTO v_is_admin;
    IF NOT v_is_admin AND p_actor_user_id <> v_vendor_user AND p_actor_user_id <> dp.vendor_id THEN
      RAISE EXCEPTION 'NOT_OWNER';
    END IF;
  END IF;

  v_name     := COALESCE(NULLIF(btrim(dp.title), ''), NULLIF(btrim(dp.product_name), ''), 'Produit importé');
  v_price    := COALESCE(dp.selling_price, dp.cost_price, 0);
  v_currency := COALESCE(NULLIF(dp.selling_currency, ''), NULLIF(dp.cost_currency, ''), 'USD');

  IF v_price <= 0 THEN RAISE EXCEPTION 'INVALID_SELLING_PRICE'; END IF;

  -- 1) Re-publication : le miroir existe déjà → mise à jour (idempotent).
  IF dp.published_product_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.products WHERE id = dp.published_product_id) THEN
    UPDATE public.products SET
      name           = v_name,
      description     = dp.description,
      price           = v_price,
      currency        = v_currency,
      cost_price      = dp.cost_price,
      images          = COALESCE(dp.images, images),
      stock_quantity  = COALESCE(dp.stock_quantity, stock_quantity),
      is_active       = COALESCE(dp.is_available, true),
      updated_at      = now()
    WHERE id = dp.published_product_id;
    v_product_id := dp.published_product_id;
    v_action := 'updated';
  ELSE
    -- 2) Première publication : créer le produit catalogue.
    INSERT INTO public.products (
      vendor_id, name, description, price, currency, cost_price,
      images, stock_quantity, is_active, section
    ) VALUES (
      v_vendor_id, v_name, dp.description, v_price, v_currency, dp.cost_price,
      COALESCE(dp.images, '[]'::jsonb), COALESCE(dp.stock_quantity, 0),
      COALESCE(dp.is_available, true), 'dropshipping'
    )
    RETURNING id INTO v_product_id;
    v_action := 'created';
  END IF;

  -- 3) Lier + marquer publié.
  UPDATE public.dropship_products
  SET published_product_id = v_product_id,
      is_published = true,
      is_active = true
  WHERE id = p_dropship_id;

  RETURN jsonb_build_object(
    'success', true, 'action', v_action,
    'product_id', v_product_id, 'dropship_id', p_dropship_id,
    'vendor_id', v_vendor_id, 'price', v_price, 'currency', v_currency
  );
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- DÉPUBLIER : masque le produit catalogue miroir, marque le dropship non publié.
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.unpublish_dropship_product(
  p_dropship_id uuid,
  p_actor_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  dp public.dropship_products%ROWTYPE;
BEGIN
  SELECT * INTO dp FROM public.dropship_products WHERE id = p_dropship_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DROPSHIP_PRODUCT_NOT_FOUND'; END IF;

  IF dp.published_product_id IS NOT NULL THEN
    UPDATE public.products SET is_active = false, updated_at = now()
    WHERE id = dp.published_product_id;
  END IF;

  UPDATE public.dropship_products SET is_published = false WHERE id = p_dropship_id;
  RETURN jsonb_build_object('success', true, 'dropship_id', p_dropship_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.publish_dropship_product(uuid, uuid)   TO service_role;
GRANT EXECUTE ON FUNCTION public.unpublish_dropship_product(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.resolve_vendor_id(uuid)               TO service_role;

SELECT 'Bridge dropship créé : publish_dropship_product / unpublish_dropship_product (+ lien published_product_id).' AS status;
