
-- =============================================
-- 1. TABLE user_activity — Tracking unifié (connecté + invité)
-- =============================================
CREATE TABLE IF NOT EXISTS public.user_activity (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  session_id text,
  product_id uuid REFERENCES public.products(id) ON DELETE CASCADE,
  vendor_id uuid,
  category_id uuid,
  action_type text NOT NULL,
  query text,
  metadata jsonb DEFAULT '{}',
  device_type text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Index performants
CREATE INDEX IF NOT EXISTS idx_user_activity_user_id ON public.user_activity(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_activity_product_id ON public.user_activity(product_id) WHERE product_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_activity_action_type ON public.user_activity(action_type);
CREATE INDEX IF NOT EXISTS idx_user_activity_created_at ON public.user_activity(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_user_activity_session ON public.user_activity(session_id) WHERE session_id IS NOT NULL;

-- RLS
ALTER TABLE public.user_activity ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can insert own activity" ON public.user_activity
  FOR INSERT TO authenticated
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Anon can insert activity with session" ON public.user_activity
  FOR INSERT TO anon
  WITH CHECK (user_id IS NULL AND session_id IS NOT NULL);

CREATE POLICY "Users can read own activity" ON public.user_activity
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

-- =============================================
-- 2. TABLE user_category_preferences — Préférences calculées
-- =============================================
CREATE TABLE IF NOT EXISTS public.user_category_preferences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  category_id uuid NOT NULL,
  score numeric NOT NULL DEFAULT 0,
  vendor_affinity jsonb DEFAULT '{}',
  last_updated timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, category_id)
);

CREATE INDEX IF NOT EXISTS idx_ucp_user_score ON public.user_category_preferences(user_id, score DESC);

ALTER TABLE public.user_category_preferences ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users read own prefs" ON public.user_category_preferences
  FOR SELECT TO authenticated
  USING (auth.uid() = user_id);

-- =============================================
-- 3. TABLE product_scores — Score global produit pré-calculé
-- =============================================
CREATE TABLE IF NOT EXISTS public.product_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE UNIQUE,
  views_count int NOT NULL DEFAULT 0,
  clicks_count int NOT NULL DEFAULT 0,
  cart_count int NOT NULL DEFAULT 0,
  purchases_count int NOT NULL DEFAULT 0,
  conversion_rate numeric DEFAULT 0,
  total_score numeric NOT NULL DEFAULT 0,
  trending_score numeric DEFAULT 0,
  is_featured boolean DEFAULT false,
  last_computed timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_scores_total ON public.product_scores(total_score DESC);
CREATE INDEX IF NOT EXISTS idx_product_scores_trending ON public.product_scores(trending_score DESC);

ALTER TABLE public.product_scores ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can read scores" ON public.product_scores
  FOR SELECT TO anon, authenticated
  USING (true);

-- =============================================
-- 4. FUNCTION: Recalculate product scores
-- =============================================
CREATE OR REPLACE FUNCTION public.compute_product_scores()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.id AS product_id,
      COALESCE(v.cnt, 0) AS views,
      COALESCE(cl.cnt, 0) AS clicks,
      COALESCE(ca.cnt, 0) AS carts,
      COALESCE(pu.cnt, 0) AS purchases,
      p.is_featured
    FROM products p
    LEFT JOIN (
      SELECT product_id, count(*) AS cnt FROM user_activity
      WHERE action_type = 'product_view' AND created_at > now() - interval '30 days'
      GROUP BY product_id
    ) v ON v.product_id = p.id
    LEFT JOIN (
      SELECT product_id, count(*) AS cnt FROM user_activity
      WHERE action_type = 'product_click' AND created_at > now() - interval '30 days'
      GROUP BY product_id
    ) cl ON cl.product_id = p.id
    LEFT JOIN (
      SELECT product_id, count(*) AS cnt FROM user_activity
      WHERE action_type = 'add_to_cart' AND created_at > now() - interval '30 days'
      GROUP BY product_id
    ) ca ON ca.product_id = p.id
    LEFT JOIN (
      SELECT product_id, count(*) AS cnt FROM user_activity
      WHERE action_type = 'purchase' AND created_at > now() - interval '30 days'
      GROUP BY product_id
    ) pu ON pu.product_id = p.id
    WHERE p.is_active = true
  LOOP
    INSERT INTO product_scores (product_id, views_count, clicks_count, cart_count, purchases_count, conversion_rate, total_score, trending_score, is_featured, last_computed)
    VALUES (
      r.product_id,
      r.views,
      r.clicks,
      r.carts,
      r.purchases,
      CASE WHEN r.views > 0 THEN round(r.purchases::numeric / r.views, 4) ELSE 0 END,
      r.purchases * 5 + r.carts * 3 + r.clicks * 2 + r.views * 1 + (CASE WHEN r.is_featured THEN 20 ELSE 0 END),
      -- trending = weighted recent activity (7 days bonus)
      r.purchases * 10 + r.carts * 5 + r.clicks * 3 + r.views * 1,
      COALESCE(r.is_featured, false),
      now()
    )
    ON CONFLICT (product_id) DO UPDATE SET
      views_count = EXCLUDED.views_count,
      clicks_count = EXCLUDED.clicks_count,
      cart_count = EXCLUDED.cart_count,
      purchases_count = EXCLUDED.purchases_count,
      conversion_rate = EXCLUDED.conversion_rate,
      total_score = EXCLUDED.total_score,
      trending_score = EXCLUDED.trending_score,
      is_featured = EXCLUDED.is_featured,
      last_computed = now();
  END LOOP;
END;
$$;

-- =============================================
-- 5. FUNCTION: Update user category preferences
-- =============================================
CREATE OR REPLACE FUNCTION public.compute_user_preferences(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Upsert preferences based on activity
  INSERT INTO user_category_preferences (user_id, category_id, score, last_updated)
  SELECT
    p_user_id,
    p.category_id,
    SUM(
      CASE ua.action_type
        WHEN 'purchase' THEN 5
        WHEN 'add_to_cart' THEN 3
        WHEN 'product_click' THEN 2
        WHEN 'product_view' THEN 1
        WHEN 'search' THEN 2
        ELSE 1
      END
    ) AS score,
    now()
  FROM user_activity ua
  JOIN products p ON p.id = ua.product_id
  WHERE ua.user_id = p_user_id
    AND p.category_id IS NOT NULL
    AND ua.created_at > now() - interval '90 days'
  GROUP BY p.category_id
  ON CONFLICT (user_id, category_id) DO UPDATE SET
    score = EXCLUDED.score,
    last_updated = now();
END;
$$;

-- =============================================
-- 6. FUNCTION: Get smart recommendations
-- =============================================
CREATE OR REPLACE FUNCTION public.get_smart_recommendations(
  p_user_id uuid DEFAULT NULL,
  p_limit int DEFAULT 20,
  p_type text DEFAULT 'home'
)
RETURNS TABLE(
  product_id uuid,
  name text,
  price numeric,
  images jsonb,
  rating numeric,
  vendor_id uuid,
  vendor_name text,
  currency text,
  score numeric,
  reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_user_id IS NOT NULL AND p_type = 'home' THEN
    -- Personalized: user preferences + product scores
    RETURN QUERY
    SELECT
      p.id AS product_id,
      p.name,
      p.price,
      p.images,
      p.rating,
      p.vendor_id,
      COALESCE(vnd.business_name, 'Vendeur') AS vendor_name,
      COALESCE(p.currency, 'GNF') AS currency,
      COALESCE(ps.total_score, 0) + COALESCE(ucp.score, 0) * 2 AS score,
      CASE
        WHEN ucp.score > 10 THEN 'Basé sur vos achats'
        WHEN ucp.score > 5 THEN 'Basé sur vos intérêts'
        ELSE 'Populaire'
      END AS reason
    FROM products p
    JOIN vendors vnd ON vnd.id = p.vendor_id
    LEFT JOIN product_scores ps ON ps.product_id = p.id
    LEFT JOIN user_category_preferences ucp ON ucp.user_id = p_user_id AND ucp.category_id = p.category_id
    WHERE p.is_active = true
      AND vnd.business_type IN ('hybrid', 'online')
    ORDER BY (COALESCE(ps.total_score, 0) + COALESCE(ucp.score, 0) * 2) DESC
    LIMIT p_limit;
  ELSE
    -- Fallback: popular products
    RETURN QUERY
    SELECT
      p.id AS product_id,
      p.name,
      p.price,
      p.images,
      p.rating,
      p.vendor_id,
      COALESCE(vnd.business_name, 'Vendeur') AS vendor_name,
      COALESCE(p.currency, 'GNF') AS currency,
      COALESCE(ps.total_score, 0) AS score,
      'Populaire'::text AS reason
    FROM products p
    JOIN vendors vnd ON vnd.id = p.vendor_id
    LEFT JOIN product_scores ps ON ps.product_id = p.id
    WHERE p.is_active = true
      AND vnd.business_type IN ('hybrid', 'online')
    ORDER BY COALESCE(ps.total_score, 0) DESC, p.rating DESC NULLS LAST
    LIMIT p_limit;
  END IF;
END;
$$;

-- =============================================
-- 7. FUNCTION: Get similar products (improved)
-- =============================================
CREATE OR REPLACE FUNCTION public.get_smart_similar_products(
  p_product_id uuid,
  p_limit int DEFAULT 10
)
RETURNS TABLE(
  product_id uuid,
  name text,
  price numeric,
  images jsonb,
  rating numeric,
  vendor_id uuid,
  vendor_name text,
  currency text,
  score numeric,
  reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_category_id uuid;
  v_price numeric;
  v_vendor_id uuid;
BEGIN
  SELECT p.category_id, p.price, p.vendor_id
  INTO v_category_id, v_price, v_vendor_id
  FROM products p WHERE p.id = p_product_id;

  RETURN QUERY
  SELECT
    p.id AS product_id,
    p.name,
    p.price,
    p.images,
    p.rating,
    p.vendor_id,
    COALESCE(vnd.business_name, 'Vendeur') AS vendor_name,
    COALESCE(p.currency, 'GNF') AS currency,
    (
      CASE WHEN p.category_id = v_category_id THEN 10 ELSE 0 END +
      CASE WHEN p.vendor_id = v_vendor_id THEN 3 ELSE 0 END +
      CASE WHEN ABS(p.price - v_price) < v_price * 0.3 THEN 5 ELSE 0 END +
      COALESCE(ps.total_score, 0) * 0.1
    ) AS score,
    'Produit similaire'::text AS reason
  FROM products p
  JOIN vendors vnd ON vnd.id = p.vendor_id
  LEFT JOIN product_scores ps ON ps.product_id = p.id
  WHERE p.is_active = true
    AND p.id != p_product_id
    AND vnd.business_type IN ('hybrid', 'online')
    AND (p.category_id = v_category_id OR ABS(p.price - v_price) < v_price * 0.5)
  ORDER BY score DESC
  LIMIT p_limit;
END;
$$;

-- =============================================
-- 8. FUNCTION: Get popular/trending
-- =============================================
CREATE OR REPLACE FUNCTION public.get_trending_products(
  p_limit int DEFAULT 16
)
RETURNS TABLE(
  product_id uuid,
  name text,
  price numeric,
  images jsonb,
  rating numeric,
  vendor_id uuid,
  vendor_name text,
  currency text,
  score numeric,
  reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    p.id AS product_id,
    p.name,
    p.price,
    p.images,
    p.rating,
    p.vendor_id,
    COALESCE(vnd.business_name, 'Vendeur') AS vendor_name,
    COALESCE(p.currency, 'GNF') AS currency,
    COALESCE(ps.trending_score, 0) AS score,
    'Tendance'::text AS reason
  FROM products p
  JOIN vendors vnd ON vnd.id = p.vendor_id
  LEFT JOIN product_scores ps ON ps.product_id = p.id
  WHERE p.is_active = true
    AND vnd.business_type IN ('hybrid', 'online')
  ORDER BY COALESCE(ps.trending_score, 0) DESC, p.created_at DESC
  LIMIT p_limit;
END;
$$;

-- =============================================
-- 9. FUNCTION: Recently viewed by user
-- =============================================
CREATE OR REPLACE FUNCTION public.get_recently_viewed(
  p_user_id uuid,
  p_limit int DEFAULT 12
)
RETURNS TABLE(
  product_id uuid,
  name text,
  price numeric,
  images jsonb,
  rating numeric,
  vendor_id uuid,
  vendor_name text,
  currency text,
  score numeric,
  reason text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT DISTINCT ON (ua.product_id)
    p.id AS product_id,
    p.name,
    p.price,
    p.images,
    p.rating,
    p.vendor_id,
    COALESCE(vnd.business_name, 'Vendeur') AS vendor_name,
    COALESCE(p.currency, 'GNF') AS currency,
    0::numeric AS score,
    'Récemment consulté'::text AS reason
  FROM user_activity ua
  JOIN products p ON p.id = ua.product_id
  JOIN vendors vnd ON vnd.id = p.vendor_id
  WHERE ua.user_id = p_user_id
    AND ua.action_type IN ('product_view', 'product_click')
    AND p.is_active = true
  ORDER BY ua.product_id, ua.created_at DESC
  LIMIT p_limit;
END;
$$;
