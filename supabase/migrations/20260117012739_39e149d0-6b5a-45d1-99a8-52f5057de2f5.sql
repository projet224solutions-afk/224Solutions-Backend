-- ============================================================================
-- ANALYTICS PERFORMANCE OPTIMIZATION
-- Optimized indexes + raw tables for batch processing
-- Fixed: Using trigger instead of generated column for view_date
-- ============================================================================

-- ============================================================================
-- 1. RAW TABLES FOR BATCH INSERTS (High Write Throughput)
-- ============================================================================

-- Raw product views table (receives batch inserts from Redis queue)
CREATE TABLE IF NOT EXISTS public.product_views_raw (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id UUID NOT NULL,
  vendor_id UUID NOT NULL,
  user_id UUID,
  session_id TEXT,
  ip_address INET NOT NULL,
  user_agent TEXT,
  fingerprint_hash TEXT NOT NULL,
  referer_url TEXT,
  device_type TEXT DEFAULT 'unknown',
  country_code TEXT,
  tracked_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  view_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- Raw shop visits table
CREATE TABLE IF NOT EXISTS public.shop_visits_raw (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  user_id UUID,
  session_id TEXT,
  ip_address INET NOT NULL,
  user_agent TEXT,
  fingerprint_hash TEXT NOT NULL,
  referer_url TEXT,
  device_type TEXT DEFAULT 'unknown',
  country_code TEXT,
  entry_page TEXT,
  tracked_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  visit_date DATE NOT NULL DEFAULT CURRENT_DATE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);

-- ============================================================================
-- 2. TRIGGERS TO SET DATE FROM TIMESTAMP
-- ============================================================================

CREATE OR REPLACE FUNCTION set_view_date_from_tracked_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.view_date := NEW.tracked_at::date;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION set_visit_date_from_tracked_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.visit_date := NEW.tracked_at::date;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_view_date ON public.product_views_raw;
CREATE TRIGGER trg_set_view_date
  BEFORE INSERT ON public.product_views_raw
  FOR EACH ROW
  EXECUTE FUNCTION set_view_date_from_tracked_at();

DROP TRIGGER IF EXISTS trg_set_visit_date ON public.shop_visits_raw;
CREATE TRIGGER trg_set_visit_date
  BEFORE INSERT ON public.shop_visits_raw
  FOR EACH ROW
  EXECUTE FUNCTION set_visit_date_from_tracked_at();

-- ============================================================================
-- 3. OPTIMIZED INDEXES FOR RAW TABLES
-- ============================================================================

-- UNIQUE constraint for deduplication (fingerprint + target + date)
CREATE UNIQUE INDEX IF NOT EXISTS idx_product_views_raw_dedup 
ON public.product_views_raw (fingerprint_hash, product_id, view_date);

CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_visits_raw_dedup 
ON public.shop_visits_raw (fingerprint_hash, vendor_id, visit_date);

-- BTREE indexes for vendor dashboard queries
CREATE INDEX IF NOT EXISTS idx_product_views_raw_vendor_date 
ON public.product_views_raw (vendor_id, view_date DESC);

CREATE INDEX IF NOT EXISTS idx_shop_visits_raw_vendor_date 
ON public.shop_visits_raw (vendor_id, visit_date DESC);

-- Product-level analytics: product_id + date
CREATE INDEX IF NOT EXISTS idx_product_views_raw_product_date 
ON public.product_views_raw (product_id, view_date DESC);

-- ============================================================================
-- 4. AGGREGATED DAILY STATS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.analytics_daily_stats (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  stat_date DATE NOT NULL,
  total_product_views INTEGER DEFAULT 0,
  unique_product_viewers INTEGER DEFAULT 0,
  total_shop_visits INTEGER DEFAULT 0,
  unique_shop_visitors INTEGER DEFAULT 0,
  device_breakdown JSONB DEFAULT '{"desktop": 0, "mobile": 0, "tablet": 0}',
  country_breakdown JSONB DEFAULT '{}',
  top_products JSONB DEFAULT '[]',
  computed_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(vendor_id, stat_date)
);

CREATE INDEX IF NOT EXISTS idx_analytics_daily_stats_vendor_date 
ON public.analytics_daily_stats (vendor_id, stat_date DESC);

-- ============================================================================
-- 5. BLOCKED IPS TABLE FOR VENDORS
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.vendor_blocked_ips (
  id UUID NOT NULL DEFAULT gen_random_uuid() PRIMARY KEY,
  vendor_id UUID NOT NULL,
  ip_address INET NOT NULL,
  reason TEXT,
  blocked_by UUID,
  expires_at TIMESTAMP WITH TIME ZONE,
  created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now(),
  UNIQUE(vendor_id, ip_address)
);

CREATE INDEX IF NOT EXISTS idx_vendor_blocked_ips_lookup 
ON public.vendor_blocked_ips (vendor_id, ip_address);

-- ============================================================================
-- 6. ENHANCE EXISTING PRODUCT_VIEWS TABLE
-- ============================================================================

DO $$ 
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                 WHERE table_name = 'product_views' AND column_name = 'fingerprint_hash') THEN
    ALTER TABLE public.product_views ADD COLUMN fingerprint_hash TEXT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_product_views_user_product_date 
ON public.product_views (user_id, product_id, viewed_at DESC);

-- ============================================================================
-- 7. ENABLE RLS ON NEW TABLES
-- ============================================================================

ALTER TABLE public.product_views_raw ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_visits_raw ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analytics_daily_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vendor_blocked_ips ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Service role can manage product_views_raw"
ON public.product_views_raw FOR ALL USING (true) WITH CHECK (true);

CREATE POLICY "Service role can manage shop_visits_raw"
ON public.shop_visits_raw FOR ALL USING (true) WITH CHECK (true);

CREATE POLICY "Vendors can view their own daily stats"
ON public.analytics_daily_stats FOR SELECT
USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

CREATE POLICY "Vendors can manage their blocked IPs"
ON public.vendor_blocked_ips FOR ALL
USING (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()))
WITH CHECK (vendor_id IN (SELECT id FROM vendors WHERE user_id = auth.uid()));

-- ============================================================================
-- 8. FUNCTION TO COMPUTE DAILY STATS
-- ============================================================================

CREATE OR REPLACE FUNCTION compute_daily_analytics(p_date DATE DEFAULT CURRENT_DATE - 1)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_processed INTEGER := 0;
  v_vendor_id UUID;
BEGIN
  FOR v_vendor_id IN 
    SELECT DISTINCT vendor_id FROM product_views_raw WHERE view_date = p_date
    UNION
    SELECT DISTINCT vendor_id FROM shop_visits_raw WHERE visit_date = p_date
  LOOP
    INSERT INTO analytics_daily_stats (
      vendor_id, stat_date, total_product_views, unique_product_viewers,
      total_shop_visits, unique_shop_visitors, computed_at
    )
    SELECT
      v_vendor_id,
      p_date,
      (SELECT COUNT(*) FROM product_views_raw WHERE vendor_id = v_vendor_id AND view_date = p_date),
      (SELECT COUNT(DISTINCT fingerprint_hash) FROM product_views_raw WHERE vendor_id = v_vendor_id AND view_date = p_date),
      (SELECT COUNT(*) FROM shop_visits_raw WHERE vendor_id = v_vendor_id AND visit_date = p_date),
      (SELECT COUNT(DISTINCT fingerprint_hash) FROM shop_visits_raw WHERE vendor_id = v_vendor_id AND visit_date = p_date),
      now()
    ON CONFLICT (vendor_id, stat_date) DO UPDATE SET
      total_product_views = EXCLUDED.total_product_views,
      unique_product_viewers = EXCLUDED.unique_product_viewers,
      total_shop_visits = EXCLUDED.total_shop_visits,
      unique_shop_visitors = EXCLUDED.unique_shop_visitors,
      computed_at = now(),
      updated_at = now();
    
    v_processed := v_processed + 1;
  END LOOP;
  
  RETURN v_processed;
END;
$$;

COMMENT ON TABLE public.product_views_raw IS 'Raw product views from batch processing';
COMMENT ON TABLE public.shop_visits_raw IS 'Raw shop visits from batch processing';
COMMENT ON TABLE public.analytics_daily_stats IS 'Pre-computed daily analytics';
