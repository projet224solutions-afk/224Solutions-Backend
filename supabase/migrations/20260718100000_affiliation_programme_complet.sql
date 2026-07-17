-- ════════════════════════════════════════════════════════════════════════════
-- 💸 AFFILIATION PRODUITS niveau « Amazon Associates » (18/07/2026)
-- UN SEUL système : client-affilié et affilié pro passent par les MÊMES tables
-- (affiliate_clicks/affiliate_commissions) et la MÊME RPC de versement.
-- (Les systèmes agents et voyage sont distincts et INTOUCHÉS.)
-- ════════════════════════════════════════════════════════════════════════════

-- ── BLOC 0 : l'affilié côté compte (flag sur le profil, PAS un 2e compte) ──
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS affiliate_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS affiliate_consent_at timestamptz;

-- ── BLOC 2 : LA MESURE — clics ANONYMES des liens produits ──
-- (affiliate_clicks existant = ATTRIBUTION acheteur connecté ; ici = trafic.)
CREATE TABLE IF NOT EXISTS public.affiliate_product_clicks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  affiliate_user_id uuid NOT NULL,
  visitor_key text NOT NULL,
  clicked_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_apc_affiliate ON public.affiliate_product_clicks (affiliate_user_id, clicked_at DESC);
CREATE INDEX IF NOT EXISTS idx_apc_product ON public.affiliate_product_clicks (product_id, clicked_at DESC);
ALTER TABLE public.affiliate_product_clicks ENABLE ROW LEVEL SECURITY;
-- Personne ne lit/écrit en direct : écriture via RPC anti-spam, lecture via backend (service).
REVOKE ALL ON public.affiliate_product_clicks FROM anon, authenticated;

-- RPC anti-spam (pattern du tracking marketing) : 1 clic compté par
-- (visiteur, produit, affilié) par 30 min ; rafale > 30 clics/h par visiteur → ignoré.
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
  ) THEN
    RETURN jsonb_build_object('success', true, 'counted', false);
  END IF;
  -- Anti-spam 30 min (même visiteur, même produit, même affilié).
  SELECT count(*) INTO v_recent FROM public.affiliate_product_clicks
  WHERE visitor_key = p_visitor_key AND product_id = p_product_id
    AND affiliate_user_id = v_affiliate AND clicked_at > now() - interval '30 minutes';
  IF v_recent > 0 THEN RETURN jsonb_build_object('success', true, 'counted', false); END IF;
  -- Anti-rafale : > 30 clics/h par visiteur toutes cibles confondues → ignoré.
  SELECT count(*) INTO v_burst FROM public.affiliate_product_clicks
  WHERE visitor_key = p_visitor_key AND clicked_at > now() - interval '1 hour';
  IF v_burst >= 30 THEN RETURN jsonb_build_object('success', true, 'counted', false); END IF;

  INSERT INTO public.affiliate_product_clicks (product_id, affiliate_user_id, visitor_key)
  VALUES (p_product_id, v_affiliate, p_visitor_key);
  RETURN jsonb_build_object('success', true, 'counted', true);
END;
$$;
REVOKE ALL ON FUNCTION public.record_affiliate_product_click(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_affiliate_product_click(uuid, text, text) TO anon, authenticated, service_role;

-- ── BLOCS 3 & 6 : config PDG (plafond anti-fraude + seuil de versement) ──
CREATE TABLE IF NOT EXISTS public.affiliate_config (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  max_pending_per_affiliate numeric NOT NULL DEFAULT 5000000,  -- GNF
  min_payout_amount numeric NOT NULL DEFAULT 50000,            -- GNF (en-dessous : cumul)
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.affiliate_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.affiliate_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS affiliate_config_read ON public.affiliate_config;
CREATE POLICY affiliate_config_read ON public.affiliate_config FOR SELECT TO authenticated USING (true);

-- ── BLOC 5 : PALIERS de commission (optionnel vendeur, par produit) ──
CREATE TABLE IF NOT EXISTS public.affiliate_commission_tiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.digital_products(id) ON DELETE CASCADE,
  min_monthly_sales integer NOT NULL DEFAULT 0 CHECK (min_monthly_sales >= 0),
  rate numeric NOT NULL CHECK (rate > 0 AND rate <= 50),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_id, min_monthly_sales)
);
ALTER TABLE public.affiliate_commission_tiers ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS aff_tiers_public_read ON public.affiliate_commission_tiers;
CREATE POLICY aff_tiers_public_read ON public.affiliate_commission_tiers
  FOR SELECT USING (true);  -- affichés sur la marketplace (motivation visible)
DROP POLICY IF EXISTS aff_tiers_vendor_write ON public.affiliate_commission_tiers;
CREATE POLICY aff_tiers_vendor_write ON public.affiliate_commission_tiers
  FOR ALL TO authenticated
  USING (product_id IN (SELECT dp.id FROM public.digital_products dp
                        JOIN public.vendors v ON v.id = dp.vendor_id WHERE v.user_id = auth.uid()))
  WITH CHECK (product_id IN (SELECT dp.id FROM public.digital_products dp
                             JOIN public.vendors v ON v.id = dp.vendor_id WHERE v.user_id = auth.uid()));
GRANT SELECT ON public.affiliate_commission_tiers TO anon, authenticated;

-- ── BLOC 6 : SEUIL DE VERSEMENT — confirmer ≠ payer ──
-- confirmed = gagné (fenêtre passée) ; paid_at = réellement versé au wallet.
ALTER TABLE public.affiliate_commissions ADD COLUMN IF NOT EXISTS paid_at timestamptz;

-- La confirmation marque `confirmed` puis verse TOUT le solde confirmé-non-payé
-- de l'affilié SI ce solde atteint le seuil (sinon : cumul — versé plus tard).
-- MÊMES primitives financières qu'avant : wallet_debit_internal (vendeur) +
-- credit_user_wallet_safe (affilié), idempotence par id de commission.
CREATE OR REPLACE FUNCTION public.confirm_affiliate_commissions(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_count int := 0;
  v_affiliates uuid[];
BEGIN
  UPDATE public.affiliate_commissions
     SET status = 'confirmed', confirmed_at = now()
   WHERE order_id = p_order_id AND status = 'pending';
  GET DIAGNOSTICS v_count = ROW_COUNT;

  SELECT array_agg(DISTINCT affiliate_user_id) INTO v_affiliates
  FROM public.affiliate_commissions WHERE order_id = p_order_id AND status = 'confirmed';
  IF v_affiliates IS NOT NULL THEN
    PERFORM public.process_affiliate_payout(a) FROM unnest(v_affiliates) AS a;
  END IF;
  RETURN jsonb_build_object('success', true, 'confirmed', v_count);
END;
$$;

-- Verse le solde confirmé-non-payé d'un affilié SI ≥ seuil (config PDG).
CREATE OR REPLACE FUNCTION public.process_affiliate_payout(p_affiliate uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_min numeric;
  v_total numeric;
  v_row public.affiliate_commissions%ROWTYPE;
  v_vendor_user uuid;
  v_paid int := 0;
BEGIN
  SELECT min_payout_amount INTO v_min FROM public.affiliate_config WHERE id;
  v_min := COALESCE(v_min, 0);
  SELECT COALESCE(sum(commission_amount), 0) INTO v_total
  FROM public.affiliate_commissions
  WHERE affiliate_user_id = p_affiliate AND status = 'confirmed' AND paid_at IS NULL;
  IF v_total <= 0 OR v_total < v_min THEN
    RETURN jsonb_build_object('success', true, 'paid', 0, 'held', v_total);
  END IF;

  FOR v_row IN
    SELECT * FROM public.affiliate_commissions
    WHERE affiliate_user_id = p_affiliate AND status = 'confirmed' AND paid_at IS NULL
    FOR UPDATE SKIP LOCKED
  LOOP
    IF v_row.commission_amount > 0 THEN
      SELECT user_id INTO v_vendor_user FROM public.vendors WHERE id = v_row.vendor_id;
      IF v_vendor_user IS NOT NULL THEN
        PERFORM public.wallet_debit_internal(v_vendor_user, v_row.commission_amount,
          'Commission affiliation (vente #' || left(v_row.order_id::text, 8) || ')',
          'aff_comm_debit:' || v_row.id::text);
      END IF;
      PERFORM public.credit_user_wallet_safe(v_row.affiliate_user_id, v_row.commission_amount,
        NULL, 'affiliate_commission', v_row.id::text);
    END IF;
    UPDATE public.affiliate_commissions SET paid_at = now() WHERE id = v_row.id;
    v_paid := v_paid + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'paid', v_paid, 'held', 0);
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_affiliate_commissions(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_affiliate_commissions(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.process_affiliate_payout(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_affiliate_payout(uuid) TO service_role;
