-- ============================================================================
-- 📊 ANALYTICS TRACKING SYSTEM - DATABASE SCHEMA
-- Multi-vendor marketplace analytics with deduplication and anti-fraud
-- ============================================================================

-- ============================================================================
-- 0. DROP EXISTING TABLES (clean slate for this migration)
-- ============================================================================

DROP TABLE IF EXISTS product_views CASCADE;
DROP TABLE IF EXISTS shop_visits CASCADE;
DROP TABLE IF EXISTS product_views_daily CASCADE;
DROP TABLE IF EXISTS shop_visits_daily CASCADE;
DROP TABLE IF EXISTS vendor_blocked_ips CASCADE;

DROP FUNCTION IF EXISTS track_product_view CASCADE;
DROP FUNCTION IF EXISTS track_shop_visit CASCADE;
DROP FUNCTION IF EXISTS aggregate_daily_analytics CASCADE;
DROP FUNCTION IF EXISTS cleanup_old_analytics_data CASCADE;

-- ============================================================================
-- 1. PRODUCT VIEWS TRACKING
-- ============================================================================

CREATE TABLE product_views (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    vendor_id UUID NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
    
    -- Visitor identification (one of these must be set)
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    session_id VARCHAR(128),
    
    -- Anti-fraud data
    ip_address INET NOT NULL,
    user_agent TEXT,
    fingerprint_hash VARCHAR(64), -- Browser fingerprint for additional validation
    
    -- Metadata
    referer_url TEXT,
    device_type VARCHAR(20) CHECK (device_type IN ('desktop', 'mobile', 'tablet', 'unknown')),
    country_code CHAR(2),
    
    -- Timestamps
    viewed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    view_date DATE NOT NULL DEFAULT CURRENT_DATE, -- For deduplication index (immutable)
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraint: either user_id or session_id must be present
    CONSTRAINT product_views_visitor_check CHECK (
        user_id IS NOT NULL OR session_id IS NOT NULL
    )
);

-- Unique constraint for 24h deduplication window
-- This prevents duplicate views from same visitor within 24 hours
CREATE UNIQUE INDEX IF NOT EXISTS idx_product_views_dedup_user 
ON product_views (product_id, user_id, view_date)
WHERE user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_product_views_dedup_session 
ON product_views (product_id, session_id, view_date)
WHERE user_id IS NULL AND session_id IS NOT NULL;

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_product_views_product_id ON product_views(product_id);
CREATE INDEX IF NOT EXISTS idx_product_views_vendor_id ON product_views(vendor_id);
CREATE INDEX IF NOT EXISTS idx_product_views_viewed_at ON product_views(viewed_at);
CREATE INDEX IF NOT EXISTS idx_product_views_vendor_date ON product_views(vendor_id, viewed_at DESC);
CREATE INDEX IF NOT EXISTS idx_product_views_product_date ON product_views(product_id, viewed_at DESC);

-- Composite index for analytics queries
CREATE INDEX IF NOT EXISTS idx_product_views_analytics 
ON product_views(vendor_id, product_id, viewed_at DESC);


-- ============================================================================
-- 2. SHOP VISITS TRACKING
-- ============================================================================

CREATE TABLE shop_visits (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_id UUID NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
    
    -- Visitor identification (one of these must be set)
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    session_id VARCHAR(128),
    
    -- Anti-fraud data
    ip_address INET NOT NULL,
    user_agent TEXT,
    fingerprint_hash VARCHAR(64),
    
    -- Metadata
    referer_url TEXT,
    device_type VARCHAR(20) CHECK (device_type IN ('desktop', 'mobile', 'tablet', 'unknown')),
    country_code CHAR(2),
    entry_page VARCHAR(255), -- Which page they landed on
    
    -- Timestamps
    visited_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    visit_date DATE NOT NULL DEFAULT CURRENT_DATE, -- For deduplication index (immutable)
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    -- Constraint: either user_id or session_id must be present
    CONSTRAINT shop_visits_visitor_check CHECK (
        user_id IS NOT NULL OR session_id IS NOT NULL
    )
);

-- Unique constraint for 24h deduplication window
CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_visits_dedup_user 
ON shop_visits (vendor_id, user_id, visit_date)
WHERE user_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_visits_dedup_session 
ON shop_visits (vendor_id, session_id, visit_date)
WHERE user_id IS NULL AND session_id IS NOT NULL;

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_shop_visits_vendor_id ON shop_visits(vendor_id);
CREATE INDEX IF NOT EXISTS idx_shop_visits_visited_at ON shop_visits(visited_at);
CREATE INDEX IF NOT EXISTS idx_shop_visits_vendor_date ON shop_visits(vendor_id, visited_at DESC);


-- ============================================================================
-- 3. DAILY AGGREGATED STATS (for performance optimization)
-- ============================================================================

-- Product views daily aggregation
CREATE TABLE product_views_daily (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    vendor_id UUID NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    
    -- Aggregated counts
    total_views INTEGER NOT NULL DEFAULT 0,
    unique_visitors INTEGER NOT NULL DEFAULT 0,
    authenticated_views INTEGER NOT NULL DEFAULT 0,
    anonymous_views INTEGER NOT NULL DEFAULT 0,
    
    -- Device breakdown
    desktop_views INTEGER NOT NULL DEFAULT 0,
    mobile_views INTEGER NOT NULL DEFAULT 0,
    tablet_views INTEGER NOT NULL DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT product_views_daily_unique UNIQUE (product_id, date)
);

CREATE INDEX IF NOT EXISTS idx_product_views_daily_vendor ON product_views_daily(vendor_id, date DESC);
CREATE INDEX IF NOT EXISTS idx_product_views_daily_product ON product_views_daily(product_id, date DESC);


-- Shop visits daily aggregation
CREATE TABLE shop_visits_daily (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_id UUID NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    
    -- Aggregated counts
    total_visits INTEGER NOT NULL DEFAULT 0,
    unique_visitors INTEGER NOT NULL DEFAULT 0,
    authenticated_visits INTEGER NOT NULL DEFAULT 0,
    anonymous_visits INTEGER NOT NULL DEFAULT 0,
    
    -- Device breakdown
    desktop_visits INTEGER NOT NULL DEFAULT 0,
    mobile_visits INTEGER NOT NULL DEFAULT 0,
    tablet_visits INTEGER NOT NULL DEFAULT 0,
    
    -- Timestamps
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    
    CONSTRAINT shop_visits_daily_unique UNIQUE (vendor_id, date)
);

CREATE INDEX IF NOT EXISTS idx_shop_visits_daily_vendor ON shop_visits_daily(vendor_id, date DESC);


-- ============================================================================
-- 4. VENDOR BLOCKED IPS (anti-fraud)
-- ============================================================================

CREATE TABLE vendor_blocked_ips (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    vendor_id UUID NOT NULL REFERENCES vendors(id) ON DELETE CASCADE,
    ip_address INET NOT NULL,
    reason VARCHAR(255),
    blocked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ,
    
    CONSTRAINT vendor_blocked_ips_unique UNIQUE (vendor_id, ip_address)
);

CREATE INDEX IF NOT EXISTS idx_vendor_blocked_ips_vendor ON vendor_blocked_ips(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vendor_blocked_ips_ip ON vendor_blocked_ips(ip_address);


-- ============================================================================
-- 5. FUNCTIONS FOR SAFE INSERTION WITH DEDUPLICATION
-- ============================================================================

-- Function to track product view with deduplication
CREATE OR REPLACE FUNCTION track_product_view(
    p_product_id UUID,
    p_vendor_id UUID,
    p_user_id UUID,
    p_session_id VARCHAR(128),
    p_ip_address INET,
    p_user_agent TEXT,
    p_fingerprint_hash VARCHAR(64),
    p_referer_url TEXT,
    p_device_type VARCHAR(20),
    p_country_code CHAR(2)
)
RETURNS TABLE(success BOOLEAN, message TEXT, view_id UUID)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_existing_id UUID;
    v_new_id UUID;
    v_today DATE := CURRENT_DATE;
BEGIN
    -- Check if view already exists for this visitor today
    IF p_user_id IS NOT NULL THEN
        SELECT id INTO v_existing_id
        FROM product_views
        WHERE product_id = p_product_id
          AND user_id = p_user_id
          AND view_date = v_today;
    ELSE
        SELECT id INTO v_existing_id
        FROM product_views
        WHERE product_id = p_product_id
          AND session_id = p_session_id
          AND user_id IS NULL
          AND view_date = v_today;
    END IF;
    
    -- If already viewed today, return existing
    IF v_existing_id IS NOT NULL THEN
        RETURN QUERY SELECT FALSE, 'View already recorded today'::TEXT, v_existing_id;
        RETURN;
    END IF;
    
    -- Insert new view
    INSERT INTO product_views (
        product_id, vendor_id, user_id, session_id,
        ip_address, user_agent, fingerprint_hash,
        referer_url, device_type, country_code, view_date
    )
    VALUES (
        p_product_id, p_vendor_id, p_user_id, p_session_id,
        p_ip_address, p_user_agent, p_fingerprint_hash,
        p_referer_url, p_device_type, p_country_code, v_today
    )
    RETURNING id INTO v_new_id;
    
    RETURN QUERY SELECT TRUE, 'View recorded successfully'::TEXT, v_new_id;
END;
$$;


-- Function to track shop visit with deduplication
CREATE OR REPLACE FUNCTION track_shop_visit(
    p_vendor_id UUID,
    p_user_id UUID,
    p_session_id VARCHAR(128),
    p_ip_address INET,
    p_user_agent TEXT,
    p_fingerprint_hash VARCHAR(64),
    p_referer_url TEXT,
    p_device_type VARCHAR(20),
    p_country_code CHAR(2),
    p_entry_page VARCHAR(255)
)
RETURNS TABLE(success BOOLEAN, message TEXT, visit_id UUID)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_existing_id UUID;
    v_new_id UUID;
    v_today DATE := CURRENT_DATE;
BEGIN
    -- Check if visit already exists for this visitor today
    IF p_user_id IS NOT NULL THEN
        SELECT id INTO v_existing_id
        FROM shop_visits
        WHERE vendor_id = p_vendor_id
          AND user_id = p_user_id
          AND visit_date = v_today;
    ELSE
        SELECT id INTO v_existing_id
        FROM shop_visits
        WHERE vendor_id = p_vendor_id
          AND session_id = p_session_id
          AND user_id IS NULL
          AND visit_date = v_today;
    END IF;
    
    -- If already visited today, return existing
    IF v_existing_id IS NOT NULL THEN
        RETURN QUERY SELECT FALSE, 'Visit already recorded today'::TEXT, v_existing_id;
        RETURN;
    END IF;
    
    -- Insert new visit
    INSERT INTO shop_visits (
        vendor_id, user_id, session_id,
        ip_address, user_agent, fingerprint_hash,
        referer_url, device_type, country_code, entry_page, visit_date
    )
    VALUES (
        p_vendor_id, p_user_id, p_session_id,
        p_ip_address, p_user_agent, p_fingerprint_hash,
        p_referer_url, p_device_type, p_country_code, p_entry_page, v_today
    )
    RETURNING id INTO v_new_id;
    
    RETURN QUERY SELECT TRUE, 'Visit recorded successfully'::TEXT, v_new_id;
END;
$$;


-- ============================================================================
-- 6. FUNCTION FOR DAILY AGGREGATION (to be called by cron job)
-- ============================================================================

CREATE OR REPLACE FUNCTION aggregate_daily_analytics(p_date DATE DEFAULT CURRENT_DATE - INTERVAL '1 day')
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Aggregate product views
    INSERT INTO product_views_daily (
        product_id, vendor_id, date,
        total_views, unique_visitors, authenticated_views, anonymous_views,
        desktop_views, mobile_views, tablet_views
    )
    SELECT 
        product_id,
        vendor_id,
        view_date,
        COUNT(*) as total_views,
        COUNT(DISTINCT COALESCE(user_id::TEXT, session_id)) as unique_visitors,
        COUNT(*) FILTER (WHERE user_id IS NOT NULL) as authenticated_views,
        COUNT(*) FILTER (WHERE user_id IS NULL) as anonymous_views,
        COUNT(*) FILTER (WHERE device_type = 'desktop') as desktop_views,
        COUNT(*) FILTER (WHERE device_type = 'mobile') as mobile_views,
        COUNT(*) FILTER (WHERE device_type = 'tablet') as tablet_views
    FROM product_views
    WHERE view_date = p_date
    GROUP BY product_id, vendor_id, view_date
    ON CONFLICT (product_id, date) 
    DO UPDATE SET
        total_views = EXCLUDED.total_views,
        unique_visitors = EXCLUDED.unique_visitors,
        authenticated_views = EXCLUDED.authenticated_views,
        anonymous_views = EXCLUDED.anonymous_views,
        desktop_views = EXCLUDED.desktop_views,
        mobile_views = EXCLUDED.mobile_views,
        tablet_views = EXCLUDED.tablet_views,
        updated_at = NOW();
    
    -- Aggregate shop visits
    INSERT INTO shop_visits_daily (
        vendor_id, date,
        total_visits, unique_visitors, authenticated_visits, anonymous_visits,
        desktop_visits, mobile_visits, tablet_visits
    )
    SELECT 
        vendor_id,
        visit_date,
        COUNT(*) as total_visits,
        COUNT(DISTINCT COALESCE(user_id::TEXT, session_id)) as unique_visitors,
        COUNT(*) FILTER (WHERE user_id IS NOT NULL) as authenticated_visits,
        COUNT(*) FILTER (WHERE user_id IS NULL) as anonymous_visits,
        COUNT(*) FILTER (WHERE device_type = 'desktop') as desktop_visits,
        COUNT(*) FILTER (WHERE device_type = 'mobile') as mobile_visits,
        COUNT(*) FILTER (WHERE device_type = 'tablet') as tablet_visits
    FROM shop_visits
    WHERE visit_date = p_date
    GROUP BY vendor_id, visit_date
    ON CONFLICT (vendor_id, date) 
    DO UPDATE SET
        total_visits = EXCLUDED.total_visits,
        unique_visitors = EXCLUDED.unique_visitors,
        authenticated_visits = EXCLUDED.authenticated_visits,
        anonymous_visits = EXCLUDED.anonymous_visits,
        desktop_visits = EXCLUDED.desktop_visits,
        mobile_visits = EXCLUDED.mobile_visits,
        tablet_visits = EXCLUDED.tablet_visits,
        updated_at = NOW();
END;
$$;


-- ============================================================================
-- 7. ROW LEVEL SECURITY POLICIES
-- ============================================================================

-- Enable RLS
ALTER TABLE product_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop_visits ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_views_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE shop_visits_daily ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendor_blocked_ips ENABLE ROW LEVEL SECURITY;

-- Vendors can only read their own analytics
CREATE POLICY "Vendors can view their own product views"
ON product_views FOR SELECT
TO authenticated
USING (vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
));

CREATE POLICY "Vendors can view their own shop visits"
ON shop_visits FOR SELECT
TO authenticated
USING (vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
));

CREATE POLICY "Vendors can view their own daily product stats"
ON product_views_daily FOR SELECT
TO authenticated
USING (vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
));

CREATE POLICY "Vendors can view their own daily shop stats"
ON shop_visits_daily FOR SELECT
TO authenticated
USING (vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
));

-- Vendors can manage their blocked IPs
CREATE POLICY "Vendors can manage their blocked IPs"
ON vendor_blocked_ips FOR ALL
TO authenticated
USING (vendor_id IN (
    SELECT id FROM vendors WHERE user_id = auth.uid()
));

-- Service role can insert tracking data (bypasses RLS)
-- This is handled by the backend using supabaseAdmin client


-- ============================================================================
-- 8. CLEANUP OLD DATA (retention policy - keep 90 days of raw data)
-- ============================================================================

CREATE OR REPLACE FUNCTION cleanup_old_analytics_data()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_deleted_count INTEGER := 0;
    v_temp_count INTEGER;
BEGIN
    -- Delete product views older than 90 days
    DELETE FROM product_views
    WHERE viewed_at < NOW() - INTERVAL '90 days';
    GET DIAGNOSTICS v_temp_count = ROW_COUNT;
    v_deleted_count := v_deleted_count + v_temp_count;
    
    -- Delete shop visits older than 90 days
    DELETE FROM shop_visits
    WHERE visited_at < NOW() - INTERVAL '90 days';
    GET DIAGNOSTICS v_temp_count = ROW_COUNT;
    v_deleted_count := v_deleted_count + v_temp_count;
    
    -- Delete expired blocked IPs
    DELETE FROM vendor_blocked_ips
    WHERE expires_at IS NOT NULL AND expires_at < NOW();
    GET DIAGNOSTICS v_temp_count = ROW_COUNT;
    v_deleted_count := v_deleted_count + v_temp_count;
    
    RETURN v_deleted_count;
END;
$$;


-- ============================================================================
-- 9. COMMENTS FOR DOCUMENTATION
-- ============================================================================

COMMENT ON TABLE product_views IS 'Raw product view events with 24h deduplication per visitor';
COMMENT ON TABLE shop_visits IS 'Raw shop visit events with 24h deduplication per visitor';
COMMENT ON TABLE product_views_daily IS 'Daily aggregated product view statistics for fast querying';
COMMENT ON TABLE shop_visits_daily IS 'Daily aggregated shop visit statistics for fast querying';
COMMENT ON TABLE vendor_blocked_ips IS 'IPs blocked by vendors for anti-fraud purposes';
COMMENT ON FUNCTION track_product_view IS 'Safely track a product view with automatic deduplication';
COMMENT ON FUNCTION track_shop_visit IS 'Safely track a shop visit with automatic deduplication';
COMMENT ON FUNCTION aggregate_daily_analytics IS 'Aggregate raw tracking data into daily stats (run via cron)';
COMMENT ON FUNCTION cleanup_old_analytics_data IS 'Remove tracking data older than 90 days (run via cron)';
