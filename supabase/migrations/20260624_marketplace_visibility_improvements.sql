-- ============================================================================
-- AMÉLIORATION DU SYSTÈME DE POSITIONNEMENT MARKETPLACE — 224SOLUTIONS
-- ============================================================================
-- RÈGLE : Aucune colonne ou table existante n'est supprimée ni modifiée.
-- Toutes les instructions sont idempotentes (ADD/CREATE ... IF NOT EXISTS,
-- ON CONFLICT DO UPDATE). Atomique (BEGIN/COMMIT + self-check DO $$).
-- ============================================================================

BEGIN;

-- ── 1. NOUVEAUX PARAMÈTRES sur marketplace_visibility_settings (additif) ─────
ALTER TABLE public.marketplace_visibility_settings
  ADD COLUMN IF NOT EXISTS new_vendor_bonus_days  INTEGER       NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS new_vendor_max_bonus   NUMERIC(5,2)  NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS trend_weight           NUMERIC(5,2)  NOT NULL DEFAULT 15,
  ADD COLUMN IF NOT EXISTS trend_window_hours     INTEGER       NOT NULL DEFAULT 24,
  ADD COLUMN IF NOT EXISTS low_stock_threshold    INTEGER       NOT NULL DEFAULT 3,
  ADD COLUMN IF NOT EXISTS low_stock_penalty      NUMERIC(5,2)  NOT NULL DEFAULT 5;

-- Rééquilibrage des poids (performance > abonnement = méritocratique).
-- Cible le seed unique config_name='default' (sans dépendre de is_active).
UPDATE public.marketplace_visibility_settings
SET
  subscription_weight = 20,   -- était 35
  performance_weight  = 35,   -- était 25
  boost_weight        = 15,   -- était 20
  quality_weight      = 15,   -- était 10
  relevance_weight    = 15,   -- était 10
  updated_at          = NOW()
WHERE config_name = 'default';

-- ── 2. BOOST GÉOLOCALISÉ (NULL = mondial, comportement actuel préservé) ──────
ALTER TABLE public.marketplace_visibility_boosts
  ADD COLUMN IF NOT EXISTS target_country TEXT,
  ADD COLUMN IF NOT EXISTS target_city    TEXT;

CREATE INDEX IF NOT EXISTS idx_visibility_boosts_geo
  ON public.marketplace_visibility_boosts (target_country, target_city)
  WHERE target_country IS NOT NULL;

-- ── 3. SIGNAUX TENDANCE (vues / paniers / achats des dernières N heures) ─────
CREATE TABLE IF NOT EXISTS public.product_trend_signals (
  id          UUID        NOT NULL DEFAULT gen_random_uuid(),
  product_id  UUID        NOT NULL,
  item_type   TEXT        NOT NULL
              CHECK (item_type IN ('product','digital_product','professional_service')),
  signal_type TEXT        NOT NULL
              CHECK (signal_type IN ('view','add_to_cart','purchase')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT product_trend_signals_pkey PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_trend_product_recent
  ON public.product_trend_signals (product_id, signal_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_trend_cleanup
  ON public.product_trend_signals (created_at);

-- RLS : insertion via RPC SECURITY DEFINER uniquement (pas d'accès direct).
ALTER TABLE public.product_trend_signals ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.record_product_trend_signal(
  p_product_id  uuid,
  p_item_type   text,
  p_signal_type text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_item_type NOT IN ('product','digital_product','professional_service') THEN
    RAISE EXCEPTION 'item_type invalide : %', p_item_type;
  END IF;
  IF p_signal_type NOT IN ('view','add_to_cart','purchase') THEN
    RAISE EXCEPTION 'signal_type invalide : %', p_signal_type;
  END IF;
  INSERT INTO public.product_trend_signals (product_id, item_type, signal_type)
  VALUES (p_product_id, p_item_type, p_signal_type);
END;
$$;

GRANT EXECUTE ON FUNCTION public.record_product_trend_signal(uuid, text, text)
  TO authenticated, anon;

CREATE OR REPLACE FUNCTION public.cleanup_old_trend_signals()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_deleted integer;
BEGIN
  DELETE FROM public.product_trend_signals
  WHERE created_at < NOW() - INTERVAL '48 hours';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

-- ── 4. CACHE FIABILITÉ VENDEUR (litiges + retours → score 0-100) ─────────────
CREATE TABLE IF NOT EXISTS public.vendor_reliability_cache (
  vendor_user_id    UUID         NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  dispute_rate      NUMERIC(6,5) NOT NULL DEFAULT 0 CHECK (dispute_rate BETWEEN 0 AND 1),
  return_rate       NUMERIC(6,5) NOT NULL DEFAULT 0 CHECK (return_rate  BETWEEN 0 AND 1),
  reliability_score NUMERIC(5,2) NOT NULL DEFAULT 100,
  computed_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  CONSTRAINT vendor_reliability_cache_pkey PRIMARY KEY (vendor_user_id)
);

ALTER TABLE public.vendor_reliability_cache ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.refresh_vendor_reliability(p_vendor_user_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total    bigint := 0;
  v_disputes bigint := 0;
  v_returns  bigint := 0;
  v_dr       numeric := 0;
  v_rr       numeric := 0;
  v_score    numeric;
BEGIN
  SELECT COUNT(*) INTO v_total
  FROM orders o
  JOIN vendors v ON v.id = o.vendor_id
  WHERE v.user_id = p_vendor_user_id
    AND o.created_at > NOW() - INTERVAL '90 days';

  IF v_total > 0 THEN
    -- Litiges (table optionnelle : order_returns sert de proxy retours/litiges si absent)
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema='public' AND table_name='vendor_disputes') THEN
      EXECUTE 'SELECT COUNT(*) FROM vendor_disputes WHERE vendor_id = $1 AND created_at > NOW() - INTERVAL ''90 days'''
        INTO v_disputes USING p_vendor_user_id;
    END IF;

    -- Retours : table order_returns (existe dans ce projet) sinon sale_returns.
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema='public' AND table_name='order_returns') THEN
      SELECT COUNT(*) INTO v_returns
      FROM order_returns r
      JOIN orders o  ON o.id = r.order_id
      JOIN vendors v ON v.id = o.vendor_id
      WHERE v.user_id = p_vendor_user_id
        AND r.created_at > NOW() - INTERVAL '90 days';
    ELSIF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema='public' AND table_name='sale_returns') THEN
      SELECT COUNT(*) INTO v_returns
      FROM sale_returns sr
      JOIN orders o  ON o.id = sr.order_id
      JOIN vendors v ON v.id = o.vendor_id
      WHERE v.user_id = p_vendor_user_id
        AND sr.created_at > NOW() - INTERVAL '90 days';
    END IF;

    v_dr := LEAST(1, v_disputes::numeric / v_total);
    v_rr := LEAST(1, v_returns::numeric  / v_total);
  END IF;

  v_score := GREATEST(0, 100 - (v_dr * 50) - (v_rr * 30));

  INSERT INTO public.vendor_reliability_cache
    (vendor_user_id, dispute_rate, return_rate, reliability_score, computed_at)
  VALUES (p_vendor_user_id, v_dr, v_rr, v_score, NOW())
  ON CONFLICT (vendor_user_id) DO UPDATE SET
    dispute_rate      = EXCLUDED.dispute_rate,
    return_rate       = EXCLUDED.return_rate,
    reliability_score = EXCLUDED.reliability_score,
    computed_at       = NOW();

  RETURN v_score;
END;
$$;

-- ── 5. VÉRIFICATION ATOMIQUE FINALE ─────────────────────────────────────────
DO $$
DECLARE v_poids_ok boolean; v_trend_ok boolean; v_geo_ok boolean; v_rel_ok boolean;
BEGIN
  SELECT (performance_weight = 35 AND subscription_weight = 20) INTO v_poids_ok
  FROM public.marketplace_visibility_settings WHERE config_name = 'default';
  IF v_poids_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'ÉCHEC ATOMICITÉ : poids non mis à jour (config_name=default introuvable ?)';
  END IF;

  SELECT EXISTS(SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='product_trend_signals') INTO v_trend_ok;
  IF NOT v_trend_ok THEN RAISE EXCEPTION 'ÉCHEC : product_trend_signals manquante'; END IF;

  SELECT EXISTS(SELECT 1 FROM information_schema.columns
    WHERE table_name='marketplace_visibility_boosts' AND column_name='target_country') INTO v_geo_ok;
  IF NOT v_geo_ok THEN RAISE EXCEPTION 'ÉCHEC : target_country manquant sur boosts'; END IF;

  SELECT EXISTS(SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='vendor_reliability_cache') INTO v_rel_ok;
  IF NOT v_rel_ok THEN RAISE EXCEPTION 'ÉCHEC : vendor_reliability_cache manquante'; END IF;

  RAISE NOTICE '✅ MIGRATION OK — poids rééquilibrés, colonnes + 2 tables + RPC créées';
END;
$$;

COMMIT;
