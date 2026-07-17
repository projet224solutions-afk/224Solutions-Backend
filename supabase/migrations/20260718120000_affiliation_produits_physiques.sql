-- ════════════════════════════════════════════════════════════════════════════
-- 💸 AFFILIATION : extension aux produits PHYSIQUES (18/07/2026)
-- MÊMES tables, MÊMES RPC, MÊME invariant financier — product_id devient
-- polymorphe (digital_products OU products), le type est tracé sur la commission.
-- ════════════════════════════════════════════════════════════════════════════

-- 1) Opt-in vendeur sur les produits physiques (bornes 1–50 %).
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS affiliate_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS affiliate_commission_rate numeric;
ALTER TABLE public.products DROP CONSTRAINT IF EXISTS products_affiliate_rate_check;
ALTER TABLE public.products ADD CONSTRAINT products_affiliate_rate_check
  CHECK (affiliate_commission_rate IS NULL OR (affiliate_commission_rate >= 1 AND affiliate_commission_rate <= 50));

-- 2) product_id polymorphe : les FK verrouillées sur digital_products sautent
--    (la validité est garantie par les résolveurs backend + RPC ; le type est
--    tracé sur affiliate_commissions.product_kind pour le reporting).
ALTER TABLE public.affiliate_clicks DROP CONSTRAINT IF EXISTS affiliate_clicks_product_id_fkey;
ALTER TABLE public.affiliate_commissions DROP CONSTRAINT IF EXISTS affiliate_commissions_product_id_fkey;
ALTER TABLE public.affiliate_commission_tiers DROP CONSTRAINT IF EXISTS affiliate_commission_tiers_product_id_fkey;
ALTER TABLE public.affiliate_commissions ADD COLUMN IF NOT EXISTS product_kind text NOT NULL DEFAULT 'digital'
  CHECK (product_kind IN ('digital', 'physical'));

-- 3) RPC clics v3 : produit DIGITAL publié OU PHYSIQUE actif.
CREATE OR REPLACE FUNCTION public.record_affiliate_product_click(
  p_product_id uuid, p_ref text, p_visitor_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_affiliate uuid;
  v_recent int;
  v_burst int;
BEGIN
  IF p_visitor_key IS NULL OR length(p_visitor_key) < 8 OR length(p_visitor_key) > 128 THEN
    RETURN jsonb_build_object('success', false, 'error', 'VISITOR_KEY_INVALIDE');
  END IF;
  SELECT id INTO v_affiliate FROM public.profiles
  WHERE public_id = p_ref AND affiliate_enabled = true;
  IF v_affiliate IS NULL THEN
    RETURN jsonb_build_object('success', true, 'counted', false);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.digital_products
    WHERE id = p_product_id AND affiliate_enabled = true AND status = 'published'
  ) AND NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE id = p_product_id AND affiliate_enabled = true AND is_active = true
  ) THEN
    RETURN jsonb_build_object('success', true, 'counted', false);
  END IF;
  SELECT count(*) INTO v_recent FROM public.affiliate_product_clicks
  WHERE visitor_key = p_visitor_key AND product_id = p_product_id
    AND affiliate_user_id = v_affiliate AND clicked_at > now() - interval '30 minutes';
  IF v_recent > 0 THEN RETURN jsonb_build_object('success', true, 'counted', false); END IF;
  SELECT count(*) INTO v_burst FROM public.affiliate_product_clicks
  WHERE visitor_key = p_visitor_key AND clicked_at > now() - interval '1 hour';
  IF v_burst >= 30 THEN RETURN jsonb_build_object('success', true, 'counted', false); END IF;

  INSERT INTO public.affiliate_product_clicks (product_id, affiliate_user_id, visitor_key)
  VALUES (p_product_id, v_affiliate, p_visitor_key);
  RETURN jsonb_build_object('success', true, 'counted', true);
END;
$$;

-- 4) Paliers : le vendeur écrit aussi sur SES produits physiques.
DROP POLICY IF EXISTS aff_tiers_vendor_write ON public.affiliate_commission_tiers;
CREATE POLICY aff_tiers_vendor_write ON public.affiliate_commission_tiers
  FOR ALL TO authenticated
  USING (
    product_id IN (SELECT dp.id FROM public.digital_products dp
                   JOIN public.vendors v ON v.id = dp.vendor_id WHERE v.user_id = auth.uid())
    OR product_id IN (SELECT p.id FROM public.products p
                      JOIN public.vendors v ON v.id = p.vendor_id WHERE v.user_id = auth.uid())
  )
  WITH CHECK (
    product_id IN (SELECT dp.id FROM public.digital_products dp
                   JOIN public.vendors v ON v.id = dp.vendor_id WHERE v.user_id = auth.uid())
    OR product_id IN (SELECT p.id FROM public.products p
                      JOIN public.vendors v ON v.id = p.vendor_id WHERE v.user_id = auth.uid())
  );
