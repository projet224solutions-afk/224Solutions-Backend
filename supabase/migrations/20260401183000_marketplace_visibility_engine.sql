-- =====================================================
-- MARKETPLACE VISIBILITY ENGINE
-- Professional, additive, non-breaking schema for visibility ranking
-- =====================================================

-- 1) Global ranking config (single-row style, but extensible)
CREATE TABLE IF NOT EXISTS public.marketplace_visibility_settings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  config_name TEXT NOT NULL UNIQUE DEFAULT 'default',
  subscription_weight NUMERIC(5,2) NOT NULL DEFAULT 35,
  performance_weight NUMERIC(5,2) NOT NULL DEFAULT 25,
  boost_weight NUMERIC(5,2) NOT NULL DEFAULT 20,
  quality_weight NUMERIC(5,2) NOT NULL DEFAULT 10,
  relevance_weight NUMERIC(5,2) NOT NULL DEFAULT 10,
  sponsored_slots_ratio NUMERIC(5,2) NOT NULL DEFAULT 20,
  popular_slots_ratio NUMERIC(5,2) NOT NULL DEFAULT 30,
  organic_slots_ratio NUMERIC(5,2) NOT NULL DEFAULT 50,
  max_boost_per_vendor INTEGER NOT NULL DEFAULT 10,
  vendor_diversity_penalty NUMERIC(5,2) NOT NULL DEFAULT 8,
  min_quality_threshold NUMERIC(5,2) NOT NULL DEFAULT 20,
  rotation_factor NUMERIC(5,2) NOT NULL DEFAULT 10,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by UUID,
  updated_by UUID
);

-- 2) Plan -> visibility base score mapping
CREATE TABLE IF NOT EXISTS public.marketplace_visibility_plan_scores (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_name TEXT NOT NULL UNIQUE,
  visibility_tier TEXT NOT NULL,
  base_score NUMERIC(8,2) NOT NULL,
  exposure_multiplier NUMERIC(8,3) NOT NULL DEFAULT 1,
  frequency_boost NUMERIC(8,3) NOT NULL DEFAULT 1,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by UUID,
  updated_by UUID
);

-- 3) Paid boosts (product or shop)
CREATE TABLE IF NOT EXISTS public.marketplace_visibility_boosts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL CHECK (target_type IN ('product', 'shop')),
  target_id UUID NOT NULL,
  placement TEXT NOT NULL DEFAULT 'general' CHECK (placement IN ('general', 'homepage', 'category', 'search')),
  category_slug TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'paused', 'expired', 'cancelled')),
  budget_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
  amount_paid NUMERIC(14,2) NOT NULL DEFAULT 0,
  boost_score NUMERIC(10,2) NOT NULL DEFAULT 0,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  payment_reference TEXT,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by UUID,
  updated_by UUID
);

CREATE INDEX IF NOT EXISTS idx_visibility_boosts_owner ON public.marketplace_visibility_boosts(owner_user_id);
CREATE INDEX IF NOT EXISTS idx_visibility_boosts_target ON public.marketplace_visibility_boosts(target_type, target_id);
CREATE INDEX IF NOT EXISTS idx_visibility_boosts_status_window ON public.marketplace_visibility_boosts(status, starts_at, ends_at);

-- 4) Optional score audit trail for explainability
CREATE TABLE IF NOT EXISTS public.marketplace_visibility_score_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id UUID NOT NULL,
  item_type TEXT NOT NULL,
  vendor_user_id UUID,
  subscription_score NUMERIC(10,3) NOT NULL,
  performance_score NUMERIC(10,3) NOT NULL,
  boost_score NUMERIC(10,3) NOT NULL,
  quality_score NUMERIC(10,3) NOT NULL,
  relevance_score NUMERIC(10,3) NOT NULL,
  final_score NUMERIC(10,3) NOT NULL,
  context JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_visibility_score_logs_item ON public.marketplace_visibility_score_logs(item_id, item_type, created_at DESC);

-- 5) Seed defaults (idempotent)
INSERT INTO public.marketplace_visibility_settings (
  config_name,
  subscription_weight,
  performance_weight,
  boost_weight,
  quality_weight,
  relevance_weight,
  sponsored_slots_ratio,
  popular_slots_ratio,
  organic_slots_ratio,
  max_boost_per_vendor,
  vendor_diversity_penalty,
  min_quality_threshold,
  rotation_factor,
  is_active
)
VALUES (
  'default',
  35, 25, 20, 10, 10,
  20, 30, 50,
  10,
  8,
  20,
  10,
  TRUE
)
ON CONFLICT (config_name) DO NOTHING;

INSERT INTO public.marketplace_visibility_plan_scores (plan_name, visibility_tier, base_score, exposure_multiplier, frequency_boost)
VALUES
  ('free', 'basic', 30, 1.00, 1.00),
  ('basic', 'basic', 35, 1.05, 1.02),
  ('pro', 'pro', 60, 1.20, 1.10),
  ('premium', 'premium', 80, 1.40, 1.20),
  ('elite', 'elite', 95, 1.60, 1.30)
ON CONFLICT (plan_name) DO NOTHING;

-- 6) Updated-at trigger helper
CREATE OR REPLACE FUNCTION public.set_marketplace_visibility_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_visibility_settings_updated_at ON public.marketplace_visibility_settings;
CREATE TRIGGER trg_visibility_settings_updated_at
BEFORE UPDATE ON public.marketplace_visibility_settings
FOR EACH ROW
EXECUTE FUNCTION public.set_marketplace_visibility_updated_at();

DROP TRIGGER IF EXISTS trg_visibility_plan_scores_updated_at ON public.marketplace_visibility_plan_scores;
CREATE TRIGGER trg_visibility_plan_scores_updated_at
BEFORE UPDATE ON public.marketplace_visibility_plan_scores
FOR EACH ROW
EXECUTE FUNCTION public.set_marketplace_visibility_updated_at();

DROP TRIGGER IF EXISTS trg_visibility_boosts_updated_at ON public.marketplace_visibility_boosts;
CREATE TRIGGER trg_visibility_boosts_updated_at
BEFORE UPDATE ON public.marketplace_visibility_boosts
FOR EACH ROW
EXECUTE FUNCTION public.set_marketplace_visibility_updated_at();

-- 7) RLS + policies (safe defaults)
ALTER TABLE public.marketplace_visibility_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_visibility_plan_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_visibility_boosts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_visibility_score_logs ENABLE ROW LEVEL SECURITY;

-- Settings and plan scores: readable to all authenticated users, writable by service role only
DROP POLICY IF EXISTS visibility_settings_read_authenticated ON public.marketplace_visibility_settings;
CREATE POLICY visibility_settings_read_authenticated
ON public.marketplace_visibility_settings
FOR SELECT
TO authenticated
USING (TRUE);

DROP POLICY IF EXISTS visibility_plan_scores_read_authenticated ON public.marketplace_visibility_plan_scores;
CREATE POLICY visibility_plan_scores_read_authenticated
ON public.marketplace_visibility_plan_scores
FOR SELECT
TO authenticated
USING (TRUE);

-- Boosts: owner can read/write own boosts
DROP POLICY IF EXISTS visibility_boosts_owner_select ON public.marketplace_visibility_boosts;
CREATE POLICY visibility_boosts_owner_select
ON public.marketplace_visibility_boosts
FOR SELECT
TO authenticated
USING (owner_user_id = auth.uid());

DROP POLICY IF EXISTS visibility_boosts_owner_insert ON public.marketplace_visibility_boosts;
CREATE POLICY visibility_boosts_owner_insert
ON public.marketplace_visibility_boosts
FOR INSERT
TO authenticated
WITH CHECK (owner_user_id = auth.uid());

DROP POLICY IF EXISTS visibility_boosts_owner_update ON public.marketplace_visibility_boosts;
CREATE POLICY visibility_boosts_owner_update
ON public.marketplace_visibility_boosts
FOR UPDATE
TO authenticated
USING (owner_user_id = auth.uid())
WITH CHECK (owner_user_id = auth.uid());

-- Score logs: read own vendor entries when vendor_user_id matches
DROP POLICY IF EXISTS visibility_score_logs_owner_select ON public.marketplace_visibility_score_logs;
CREATE POLICY visibility_score_logs_owner_select
ON public.marketplace_visibility_score_logs
FOR SELECT
TO authenticated
USING (vendor_user_id = auth.uid());
