-- Ajouter la colonne city aux tables de tracking
ALTER TABLE product_views_raw ADD COLUMN IF NOT EXISTS city TEXT;
ALTER TABLE shop_visits_raw ADD COLUMN IF NOT EXISTS city TEXT;

-- Ajouter la colonne city_breakdown à analytics_daily_stats
ALTER TABLE analytics_daily_stats ADD COLUMN IF NOT EXISTS city_breakdown JSONB DEFAULT '{}';

-- Mettre à jour la fonction track_product_view pour supporter la ville
CREATE OR REPLACE FUNCTION track_product_view(
  p_product_id UUID,
  p_vendor_id UUID,
  p_user_id UUID DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL,
  p_ip_address INET DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_fingerprint_hash TEXT DEFAULT NULL,
  p_referer_url TEXT DEFAULT NULL,
  p_device_type TEXT DEFAULT 'unknown',
  p_country_code TEXT DEFAULT NULL,
  p_city TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, view_id UUID, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_view_id UUID;
  v_today DATE := CURRENT_DATE;
BEGIN
  -- Tenter l'insertion avec déduplication 24h
  INSERT INTO product_views_raw (
    product_id,
    vendor_id,
    user_id,
    session_id,
    ip_address,
    user_agent,
    fingerprint_hash,
    referer_url,
    device_type,
    country_code,
    city,
    tracked_at,
    view_date
  ) VALUES (
    p_product_id,
    p_vendor_id,
    p_user_id,
    p_session_id,
    p_ip_address,
    p_user_agent,
    p_fingerprint_hash,
    p_referer_url,
    p_device_type,
    p_country_code,
    p_city,
    NOW(),
    v_today
  )
  ON CONFLICT (product_id, COALESCE(user_id, '00000000-0000-0000-0000-000000000000'::UUID), COALESCE(session_id, ''), view_date)
  DO NOTHING
  RETURNING id INTO v_view_id;

  IF v_view_id IS NOT NULL THEN
    RETURN QUERY SELECT true, v_view_id, 'View tracked successfully'::TEXT;
  ELSE
    RETURN QUERY SELECT false, NULL::UUID, 'View already recorded today'::TEXT;
  END IF;
END;
$$;

-- Mettre à jour la fonction track_shop_visit pour supporter la ville
CREATE OR REPLACE FUNCTION track_shop_visit(
  p_vendor_id UUID,
  p_user_id UUID DEFAULT NULL,
  p_session_id TEXT DEFAULT NULL,
  p_ip_address INET DEFAULT NULL,
  p_user_agent TEXT DEFAULT NULL,
  p_fingerprint_hash TEXT DEFAULT NULL,
  p_referer_url TEXT DEFAULT NULL,
  p_device_type TEXT DEFAULT 'unknown',
  p_country_code TEXT DEFAULT NULL,
  p_city TEXT DEFAULT NULL,
  p_entry_page TEXT DEFAULT NULL
)
RETURNS TABLE(success BOOLEAN, visit_id UUID, message TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_visit_id UUID;
  v_today DATE := CURRENT_DATE;
BEGIN
  -- Tenter l'insertion avec déduplication 24h
  INSERT INTO shop_visits_raw (
    vendor_id,
    user_id,
    session_id,
    ip_address,
    user_agent,
    fingerprint_hash,
    referer_url,
    device_type,
    country_code,
    city,
    entry_page,
    tracked_at,
    visit_date
  ) VALUES (
    p_vendor_id,
    p_user_id,
    p_session_id,
    p_ip_address,
    p_user_agent,
    p_fingerprint_hash,
    p_referer_url,
    p_device_type,
    p_country_code,
    p_city,
    p_entry_page,
    NOW(),
    v_today
  )
  ON CONFLICT (vendor_id, COALESCE(user_id, '00000000-0000-0000-0000-000000000000'::UUID), COALESCE(session_id, ''), visit_date)
  DO NOTHING
  RETURNING id INTO v_visit_id;

  IF v_visit_id IS NOT NULL THEN
    RETURN QUERY SELECT true, v_visit_id, 'Visit tracked successfully'::TEXT;
  ELSE
    RETURN QUERY SELECT false, NULL::UUID, 'Visit already recorded today'::TEXT;
  END IF;
END;
$$;

-- Créer une fonction pour agréger les stats quotidiennes incluant ville
CREATE OR REPLACE FUNCTION aggregate_daily_analytics(p_date DATE DEFAULT CURRENT_DATE)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Insérer ou mettre à jour les stats pour chaque vendor
  INSERT INTO analytics_daily_stats (
    vendor_id,
    stat_date,
    total_product_views,
    unique_product_viewers,
    total_shop_visits,
    unique_shop_visitors,
    device_breakdown,
    country_breakdown,
    city_breakdown,
    top_products,
    computed_at
  )
  SELECT 
    v.id AS vendor_id,
    p_date AS stat_date,
    COALESCE(pv.total_views, 0) AS total_product_views,
    COALESCE(pv.unique_viewers, 0) AS unique_product_viewers,
    COALESCE(sv.total_visits, 0) AS total_shop_visits,
    COALESCE(sv.unique_visitors, 0) AS unique_shop_visitors,
    COALESCE(
      (SELECT jsonb_object_agg(device_type, cnt) FROM (
        SELECT device_type, COUNT(*) as cnt 
        FROM product_views_raw 
        WHERE vendor_id = v.id AND view_date = p_date AND device_type IS NOT NULL
        GROUP BY device_type
      ) d), '{}'::jsonb
    ) AS device_breakdown,
    COALESCE(
      (SELECT jsonb_object_agg(country_code, cnt) FROM (
        SELECT country_code, COUNT(*) as cnt 
        FROM product_views_raw 
        WHERE vendor_id = v.id AND view_date = p_date AND country_code IS NOT NULL
        GROUP BY country_code
      ) c), '{}'::jsonb
    ) AS country_breakdown,
    COALESCE(
      (SELECT jsonb_object_agg(city, cnt) FROM (
        SELECT city, COUNT(*) as cnt 
        FROM product_views_raw 
        WHERE vendor_id = v.id AND view_date = p_date AND city IS NOT NULL
        GROUP BY city
      ) ct), '{}'::jsonb
    ) AS city_breakdown,
    COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('product_id', product_id, 'views', views)) FROM (
        SELECT product_id, COUNT(*) as views 
        FROM product_views_raw 
        WHERE vendor_id = v.id AND view_date = p_date
        GROUP BY product_id
        ORDER BY views DESC
        LIMIT 10
      ) tp), '[]'::jsonb
    ) AS top_products,
    NOW() AS computed_at
  FROM vendors v
  LEFT JOIN (
    SELECT vendor_id, COUNT(*) as total_views, COUNT(DISTINCT COALESCE(user_id::text, session_id)) as unique_viewers
    FROM product_views_raw
    WHERE view_date = p_date
    GROUP BY vendor_id
  ) pv ON pv.vendor_id = v.id
  LEFT JOIN (
    SELECT vendor_id, COUNT(*) as total_visits, COUNT(DISTINCT COALESCE(user_id::text, session_id)) as unique_visitors
    FROM shop_visits_raw
    WHERE visit_date = p_date
    GROUP BY vendor_id
  ) sv ON sv.vendor_id = v.id
  WHERE pv.total_views > 0 OR sv.total_visits > 0
  ON CONFLICT (vendor_id, stat_date) DO UPDATE SET
    total_product_views = EXCLUDED.total_product_views,
    unique_product_viewers = EXCLUDED.unique_product_viewers,
    total_shop_visits = EXCLUDED.total_shop_visits,
    unique_shop_visitors = EXCLUDED.unique_shop_visitors,
    device_breakdown = EXCLUDED.device_breakdown,
    country_breakdown = EXCLUDED.country_breakdown,
    city_breakdown = EXCLUDED.city_breakdown,
    top_products = EXCLUDED.top_products,
    computed_at = NOW(),
    updated_at = NOW();
END;
$$;