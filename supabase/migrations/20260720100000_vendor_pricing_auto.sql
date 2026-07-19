-- ============================================================================
-- PRIX DE VENTE AUTOMATIQUE À LA RÉCEPTION (anti-vente-à-perte)
-- Le vendeur règle sa marge UNE FOIS ; à chaque réception le nouveau prix de
-- vente est calculé (PMP × (1+marge), arrondi commercial) et APPLIQUÉ tout seul.
-- Priorité de marge : produit > catégorie > défaut vendeur. Jamais de baisse
-- automatique (proposée). Chaque changement de prix est journalisé.
-- ============================================================================

-- 1. Réglages « Prix et marges » (par vendeur). Absence de ligne → défauts.
CREATE TABLE IF NOT EXISTS public.vendor_pricing_settings (
  vendor_id uuid PRIMARY KEY,
  default_margin_percent numeric NOT NULL DEFAULT 30,
  rounding_step integer NOT NULL DEFAULT 1000,
  pricing_mode text NOT NULL DEFAULT 'auto',            -- 'auto' | 'ask'
  low_margin_threshold_percent numeric NOT NULL DEFAULT 10,
  margin_shortcuts integer[] NOT NULL DEFAULT '{20,30,50}',
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vps_mode_chk CHECK (pricing_mode IN ('auto','ask')),
  CONSTRAINT vps_pos_chk CHECK (default_margin_percent >= 0 AND rounding_step > 0 AND low_margin_threshold_percent >= 0)
);
ALTER TABLE public.vendor_pricing_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vps_service_all ON public.vendor_pricing_settings;
CREATE POLICY vps_service_all ON public.vendor_pricing_settings FOR ALL TO service_role USING (true) WITH CHECK (true);

-- 2. Marge par catégorie (optionnel, prioritaire sur le défaut).
CREATE TABLE IF NOT EXISTS public.vendor_category_margins (
  vendor_id uuid NOT NULL,
  category_id uuid NOT NULL,
  margin_percent numeric NOT NULL CHECK (margin_percent >= 0),
  PRIMARY KEY (vendor_id, category_id)
);
ALTER TABLE public.vendor_category_margins ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vcm_service_all ON public.vendor_category_margins;
CREATE POLICY vcm_service_all ON public.vendor_category_margins FOR ALL TO service_role USING (true) WITH CHECK (true);

-- 3. Marge par produit (optionnel, prioritaire sur tout).
ALTER TABLE public.products ADD COLUMN IF NOT EXISTS margin_percent numeric;

-- 4. Journal des changements de prix (traçabilité totale).
CREATE TABLE IF NOT EXISTS public.product_price_changes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  vendor_id uuid NOT NULL,
  old_price numeric,
  new_price numeric NOT NULL,
  pmp numeric,
  margin_percent numeric,
  reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ppc_product ON public.product_price_changes (product_id, created_at DESC);
ALTER TABLE public.product_price_changes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ppc_service_all ON public.product_price_changes;
CREATE POLICY ppc_service_all ON public.product_price_changes FOR ALL TO service_role USING (true) WITH CHECK (true);

-- 5. Calcul du prix de vente conseillé pour une ligne (marge applicable + arrondi).
CREATE OR REPLACE FUNCTION public.compute_selling_price(
  p_vendor_id uuid, p_product_id uuid, p_category_id uuid, p_pmp numeric
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_margin numeric; v_step int; v_mode text; v_thr numeric; v_shortcuts int[];
  v_prod_margin numeric; v_cat_margin numeric; v_price numeric; v_current numeric;
BEGIN
  SELECT default_margin_percent, rounding_step, pricing_mode, low_margin_threshold_percent, margin_shortcuts
  INTO v_margin, v_step, v_mode, v_thr, v_shortcuts
  FROM public.vendor_pricing_settings WHERE vendor_id = p_vendor_id;
  IF NOT FOUND THEN
    v_margin := 30; v_step := 1000; v_mode := 'auto'; v_thr := 10; v_shortcuts := '{20,30,50}';
  END IF;

  -- Priorité : produit > catégorie > défaut.
  SELECT margin_percent INTO v_prod_margin FROM public.products WHERE id = p_product_id;
  IF v_prod_margin IS NULL AND p_category_id IS NOT NULL THEN
    SELECT margin_percent INTO v_cat_margin FROM public.vendor_category_margins
    WHERE vendor_id = p_vendor_id AND category_id = p_category_id;
  END IF;
  v_margin := COALESCE(v_prod_margin, v_cat_margin, v_margin);

  -- Prix brut puis arrondi commercial au palier (au plus proche, planché à couvrir le PMP).
  v_price := round((p_pmp * (1 + v_margin / 100.0)) / v_step) * v_step;
  IF v_price < p_pmp THEN v_price := ceil(p_pmp / v_step) * v_step; END IF;

  SELECT price INTO v_current FROM public.products WHERE id = p_product_id;
  RETURN jsonb_build_object(
    'price', v_price, 'margin_percent', v_margin, 'step', v_step, 'mode', v_mode,
    'current_price', v_current, 'pmp', p_pmp,
    'is_loss', v_price <= p_pmp,
    'is_low_margin', p_pmp > 0 AND ((v_price - p_pmp) / p_pmp * 100.0) < v_thr,
    'shortcuts', v_shortcuts);
END $function$;

-- 6. Applique le prix de vente auto sur les lignes reçues (mode 'auto') ou renvoie
--    les suggestions (mode 'ask'). Jamais de baisse automatique (proposée). Journalise.
--    p_lines : [{ product_id, pmp, is_new }]
CREATE OR REPLACE FUNCTION public.apply_reception_pricing(
  p_vendor_id uuid, p_lines jsonb, p_reason text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_mode text; v_line jsonb; v_pid uuid; v_pmp numeric; v_new boolean;
  v_cat uuid; v_calc jsonb; v_new_price numeric; v_current numeric; v_effective numeric;
  v_updated int := 0; v_details jsonb := '[]'::jsonb; v_suggestions jsonb := '[]'::jsonb; v_loss jsonb := '[]'::jsonb;
BEGIN
  SELECT pricing_mode INTO v_mode FROM public.vendor_pricing_settings WHERE vendor_id = p_vendor_id;
  v_mode := COALESCE(v_mode, 'auto');

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
    v_pid := (v_line->>'product_id')::uuid;
    v_pmp := COALESCE((v_line->>'pmp')::numeric, 0);
    v_new := COALESCE((v_line->>'is_new')::boolean, false);
    IF v_pid IS NULL THEN CONTINUE; END IF;

    SELECT category_id, price INTO v_cat, v_current FROM public.products WHERE id = v_pid AND vendor_id = p_vendor_id;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_calc := public.compute_selling_price(p_vendor_id, v_pid, v_cat, v_pmp);
    v_new_price := (v_calc->>'price')::numeric;
    v_effective := v_current;  -- prix qui restera affiché après ce traitement

    IF v_mode = 'ask' THEN
      -- On ne touche à rien : on propose. Le prix effectif reste l'actuel.
      v_suggestions := v_suggestions || (v_calc || jsonb_build_object('product_id', v_pid));
    ELSIF v_new OR v_current IS NULL OR v_current = 0 OR v_new_price > COALESCE(v_current, 0) THEN
      -- 'auto' : applique si nouveau OU hausse (jamais de baisse imposée).
      IF v_new_price IS DISTINCT FROM v_current THEN
        UPDATE public.products SET price = v_new_price, updated_at = now() WHERE id = v_pid;
        INSERT INTO public.product_price_changes (product_id, vendor_id, old_price, new_price, pmp, margin_percent, reason)
        VALUES (v_pid, p_vendor_id, v_current, v_new_price, v_pmp, (v_calc->>'margin_percent')::numeric, COALESCE(p_reason, 'réception'));
        v_updated := v_updated + 1;
        v_details := v_details || jsonb_build_object('product_id', v_pid, 'old_price', v_current, 'new_price', v_new_price, 'margin_percent', (v_calc->>'margin_percent')::numeric);
      END IF;
      v_effective := v_new_price;
    ELSIF v_new_price < v_current THEN
      -- Coût en baisse → proposition, jamais imposée. Prix effectif inchangé.
      v_suggestions := v_suggestions || (v_calc || jsonb_build_object('product_id', v_pid, 'kind', 'lower'));
    END IF;

    -- Vente à perte = prix EFFECTIF (après traitement) ≤ PMP.
    IF v_effective IS NOT NULL AND v_effective <= v_pmp THEN
      v_loss := v_loss || jsonb_build_object('product_id', v_pid, 'price', v_effective, 'pmp', v_pmp);
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'mode', v_mode, 'updated', v_updated,
    'details', v_details, 'suggestions', v_suggestions, 'loss', v_loss);
END $function$;

REVOKE ALL ON FUNCTION public.compute_selling_price(uuid,uuid,uuid,numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.compute_selling_price(uuid,uuid,uuid,numeric) TO service_role;
REVOKE ALL ON FUNCTION public.apply_reception_pricing(uuid,jsonb,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_reception_pricing(uuid,jsonb,text) TO service_role;
