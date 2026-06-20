-- ══════════════════════════════════════════════════════════
-- INDEX: Optimize analytics queries
-- ══════════════════════════════════════════════════════════
CREATE INDEX IF NOT EXISTS idx_analytics_daily_vendor_date 
ON analytics_daily_stats(vendor_id, stat_date DESC);

CREATE INDEX IF NOT EXISTS idx_product_views_vendor_date 
ON product_views_raw(vendor_id, tracked_at DESC);

CREATE INDEX IF NOT EXISTS idx_shop_visits_vendor_date 
ON shop_visits_raw(vendor_id, tracked_at DESC);

-- ══════════════════════════════════════════════════════════
-- VIEW: Real-time product analytics with trends
-- ══════════════════════════════════════════════════════════
CREATE OR REPLACE VIEW vendor_product_analytics AS
WITH current_period AS (
  SELECT 
    pv.product_id,
    pv.vendor_id,
    p.name AS product_name,
    p.images,
    c.name AS category_name,
    COUNT(*) AS total_views,
    COUNT(DISTINCT pv.fingerprint_hash) AS unique_views,
    jsonb_object_agg(
      COALESCE(pv.country_code, 'Unknown'), 
      cnt
    ) AS country_breakdown,
    MODE() WITHIN GROUP (ORDER BY EXTRACT(HOUR FROM pv.tracked_at)) AS peak_hour
  FROM product_views_raw pv
  JOIN products p ON pv.product_id = p.id
  LEFT JOIN categories c ON p.category_id = c.id
  LEFT JOIN LATERAL (
    SELECT pv.country_code, COUNT(*) AS cnt
    FROM product_views_raw pv2
    WHERE pv2.product_id = pv.product_id
      AND pv2.tracked_at >= CURRENT_DATE - INTERVAL '7 days'
    GROUP BY pv2.country_code
  ) cc ON true
  WHERE pv.tracked_at >= CURRENT_DATE - INTERVAL '7 days'
  GROUP BY pv.product_id, pv.vendor_id, p.name, p.images, c.name
),
previous_period AS (
  SELECT 
    pv.product_id,
    COUNT(*) AS total_views
  FROM product_views_raw pv
  WHERE pv.tracked_at >= CURRENT_DATE - INTERVAL '14 days'
    AND pv.tracked_at < CURRENT_DATE - INTERVAL '7 days'
  GROUP BY pv.product_id
)
SELECT 
  cp.product_id,
  cp.vendor_id,
  cp.product_name,
  cp.images,
  cp.category_name,
  cp.total_views,
  cp.unique_views,
  cp.country_breakdown,
  cp.peak_hour::int,
  COALESCE(pp.total_views, 0) AS previous_views,
  CASE 
    WHEN COALESCE(pp.total_views, 0) = 0 THEN 100.0
    ELSE ROUND(((cp.total_views - COALESCE(pp.total_views, 0))::numeric / 
           NULLIF(pp.total_views, 0) * 100), 1)
  END AS trend_percent
FROM current_period cp
LEFT JOIN previous_period pp ON cp.product_id = pp.product_id;

-- ══════════════════════════════════════════════════════════
-- FUNCTION: Get vendor analytics overview
-- ══════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_vendor_analytics_overview(
  p_vendor_id UUID,
  p_period TEXT DEFAULT 'week',
  p_start_date DATE DEFAULT NULL,
  p_end_date DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_start_date DATE;
  v_end_date DATE;
  v_prev_start DATE;
  v_prev_end DATE;
  v_result JSONB;
BEGIN
  v_end_date := COALESCE(p_end_date, CURRENT_DATE);
  
  CASE p_period
    WHEN 'today' THEN
      v_start_date := CURRENT_DATE;
      v_prev_start := CURRENT_DATE - INTERVAL '1 day';
      v_prev_end := CURRENT_DATE - INTERVAL '1 day';
    WHEN 'week' THEN
      v_start_date := CURRENT_DATE - INTERVAL '6 days';
      v_prev_start := CURRENT_DATE - INTERVAL '13 days';
      v_prev_end := CURRENT_DATE - INTERVAL '7 days';
    WHEN 'month' THEN
      v_start_date := CURRENT_DATE - INTERVAL '29 days';
      v_prev_start := CURRENT_DATE - INTERVAL '59 days';
      v_prev_end := CURRENT_DATE - INTERVAL '30 days';
    ELSE
      v_start_date := COALESCE(p_start_date, CURRENT_DATE - INTERVAL '6 days');
      v_prev_start := v_start_date - (v_end_date - v_start_date + 1);
      v_prev_end := v_start_date - INTERVAL '1 day';
  END CASE;

  WITH current_visits AS (
    SELECT 
      COUNT(*) AS total,
      COUNT(DISTINCT fingerprint_hash) AS unique_count
    FROM shop_visits_raw
    WHERE vendor_id = p_vendor_id
      AND tracked_at::date >= v_start_date
      AND tracked_at::date <= v_end_date
  ),
  prev_visits AS (
    SELECT COUNT(*) AS total
    FROM shop_visits_raw
    WHERE vendor_id = p_vendor_id
      AND tracked_at::date >= v_prev_start
      AND tracked_at::date <= v_prev_end
  ),
  current_views AS (
    SELECT 
      COUNT(*) AS total,
      COUNT(DISTINCT fingerprint_hash) AS unique_count
    FROM product_views_raw
    WHERE vendor_id = p_vendor_id
      AND tracked_at::date >= v_start_date
      AND tracked_at::date <= v_end_date
  ),
  prev_views AS (
    SELECT COUNT(*) AS total
    FROM product_views_raw
    WHERE vendor_id = p_vendor_id
      AND tracked_at::date >= v_prev_start
      AND tracked_at::date <= v_prev_end
  ),
  current_orders AS (
    SELECT COUNT(*) AS total
    FROM orders
    WHERE vendor_id = p_vendor_id
      AND created_at::date >= v_start_date
      AND created_at::date <= v_end_date
  ),
  prev_orders AS (
    SELECT COUNT(*) AS total
    FROM orders
    WHERE vendor_id = p_vendor_id
      AND created_at::date >= v_prev_start
      AND created_at::date <= v_prev_end
  ),
  top_prods AS (
    SELECT jsonb_agg(row_to_json(t)) AS data FROM (
      SELECT 
        product_id AS "productId",
        product_name AS name,
        total_views AS views,
        trend_percent AS trend,
        ROW_NUMBER() OVER (ORDER BY total_views DESC) AS rank
      FROM vendor_product_analytics
      WHERE vendor_id = p_vendor_id
      ORDER BY total_views DESC
      LIMIT 5
    ) t
  ),
  daily AS (
    SELECT jsonb_agg(row_to_json(d) ORDER BY d.date) AS data FROM (
      SELECT 
        day::date AS date,
        COALESCE(sv.cnt, 0) AS visits,
        COALESCE(pv.cnt, 0) AS views
      FROM generate_series(v_start_date, v_end_date, '1 day'::interval) AS day
      LEFT JOIN (
        SELECT tracked_at::date AS d, COUNT(*) AS cnt
        FROM shop_visits_raw WHERE vendor_id = p_vendor_id
        GROUP BY tracked_at::date
      ) sv ON sv.d = day::date
      LEFT JOIN (
        SELECT tracked_at::date AS d, COUNT(*) AS cnt
        FROM product_views_raw WHERE vendor_id = p_vendor_id
        GROUP BY tracked_at::date
      ) pv ON pv.d = day::date
    ) d
  )
  SELECT jsonb_build_object(
    'period', p_period,
    'dateRange', jsonb_build_object('start', v_start_date, 'end', v_end_date),
    'shopVisits', jsonb_build_object(
      'total', cv.total, 'unique', cv.unique_count,
      'trend', CASE WHEN pv.total = 0 THEN 100 ELSE ROUND(((cv.total - pv.total)::numeric / NULLIF(pv.total, 0) * 100), 1) END,
      'previousTotal', pv.total
    ),
    'productViews', jsonb_build_object(
      'total', cvw.total, 'unique', cvw.unique_count,
      'trend', CASE WHEN pvw.total = 0 THEN 100 ELSE ROUND(((cvw.total - pvw.total)::numeric / NULLIF(pvw.total, 0) * 100), 1) END,
      'previousTotal', pvw.total
    ),
    'conversionRate', jsonb_build_object(
      'value', CASE WHEN cvw.total = 0 THEN 0 ELSE ROUND((co.total::numeric / cvw.total * 100), 2) END,
      'previousValue', CASE WHEN pvw.total = 0 THEN 0 ELSE ROUND((po.total::numeric / NULLIF(pvw.total, 0) * 100), 2) END
    ),
    'topProducts', COALESCE(tp.data, '[]'::jsonb),
    'dailyBreakdown', COALESCE(db.data, '[]'::jsonb)
  ) INTO v_result
  FROM current_visits cv, prev_visits pv, current_views cvw, prev_views pvw,
       current_orders co, prev_orders po, top_prods tp, daily db;

  RETURN v_result;
END;
$$;

-- ══════════════════════════════════════════════════════════
-- FUNCTION: Get paginated product analytics
-- ══════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION get_vendor_product_analytics(
  p_vendor_id UUID,
  p_page INT DEFAULT 1,
  p_limit INT DEFAULT 20,
  p_sort TEXT DEFAULT 'views_desc'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_offset INT;
  v_total INT;
  v_result JSONB;
BEGIN
  v_offset := (p_page - 1) * p_limit;
  
  SELECT COUNT(*) INTO v_total FROM vendor_product_analytics WHERE vendor_id = p_vendor_id;

  SELECT jsonb_build_object(
    'products', COALESCE(jsonb_agg(
      jsonb_build_object(
        'productId', product_id,
        'name', product_name,
        'imageUrl', images->0,
        'category', category_name,
        'views', jsonb_build_object('total', total_views, 'unique', unique_views, 'trend', trend_percent),
        'countryBreakdown', country_breakdown,
        'peakHour', peak_hour
      )
    ), '[]'::jsonb),
    'pagination', jsonb_build_object(
      'page', p_page, 'limit', p_limit, 'total', v_total,
      'totalPages', CEIL(v_total::numeric / p_limit),
      'hasNext', (p_page * p_limit) < v_total,
      'hasPrev', p_page > 1
    )
  ) INTO v_result
  FROM (
    SELECT * FROM vendor_product_analytics
    WHERE vendor_id = p_vendor_id
    ORDER BY 
      CASE WHEN p_sort = 'views_desc' THEN total_views END DESC,
      CASE WHEN p_sort = 'views_asc' THEN total_views END ASC,
      CASE WHEN p_sort = 'trend_desc' THEN trend_percent END DESC,
      CASE WHEN p_sort = 'name_asc' THEN product_name END ASC
    LIMIT p_limit OFFSET v_offset
  ) sub;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION get_vendor_analytics_overview TO authenticated;
GRANT EXECUTE ON FUNCTION get_vendor_product_analytics TO authenticated;