
-- Drop existing functions first
DROP FUNCTION IF EXISTS public.get_similar_products(uuid, int);
DROP FUNCTION IF EXISTS public.get_personalized_recommendations(uuid, int);
DROP FUNCTION IF EXISTS public.get_also_bought_products(uuid, int);
DROP FUNCTION IF EXISTS public.get_popular_in_category(uuid, int, uuid);
DROP FUNCTION IF EXISTS public.update_popularity_on_interaction();
DROP FUNCTION IF EXISTS public.update_co_purchases();
DROP TABLE IF EXISTS public.product_co_purchases CASCADE;
DROP TABLE IF EXISTS public.product_popularity_scores CASCADE;

-- Table de scores de popularité
CREATE TABLE public.product_popularity_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid REFERENCES public.products(id) ON DELETE CASCADE NOT NULL UNIQUE,
  view_count int DEFAULT 0,
  cart_count int DEFAULT 0,
  purchase_count int DEFAULT 0,
  popularity_score numeric DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_pps_score ON public.product_popularity_scores(popularity_score DESC);
ALTER TABLE public.product_popularity_scores ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read popularity scores" ON public.product_popularity_scores FOR SELECT TO public USING (true);

-- Table de co-achats
CREATE TABLE public.product_co_purchases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  related_product_id uuid REFERENCES public.products(id) ON DELETE CASCADE NOT NULL,
  co_purchase_count int DEFAULT 1,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(product_id, related_product_id)
);
CREATE INDEX idx_pcp_product ON public.product_co_purchases(product_id, co_purchase_count DESC);
ALTER TABLE public.product_co_purchases ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read co-purchases" ON public.product_co_purchases FOR SELECT TO public USING (true);

-- Fonction: Produits similaires
CREATE FUNCTION public.get_similar_products(p_product_id uuid, p_limit int DEFAULT 10)
RETURNS TABLE(product_id uuid, name text, price numeric, images text[], rating numeric, category_id uuid, similarity_score numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_category_id uuid; v_tags text[];
BEGIN
  SELECT p.category_id, p.tags INTO v_category_id, v_tags FROM products p WHERE p.id = p_product_id;
  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, p.category_id,
    (CASE WHEN p.category_id = v_category_id THEN 50 ELSE 0 END +
     CASE WHEN p.tags IS NOT NULL AND v_tags IS NOT NULL AND p.tags && v_tags THEN 30 ELSE 0 END +
     COALESCE((SELECT pps.popularity_score FROM product_popularity_scores pps WHERE pps.product_id = p.id), 0)::numeric * 0.2
    )::numeric AS similarity_score
  FROM products p
  WHERE p.id != p_product_id AND p.is_active = true
    AND (p.category_id = v_category_id OR (p.tags IS NOT NULL AND v_tags IS NOT NULL AND p.tags && v_tags))
  ORDER BY similarity_score DESC LIMIT p_limit;
END; $$;

-- Fonction: Recommandations personnalisées
CREATE FUNCTION public.get_personalized_recommendations(p_user_id uuid, p_limit int DEFAULT 12)
RETURNS TABLE(product_id uuid, name text, price numeric, images text[], rating numeric, category_id uuid, recommendation_score numeric, reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  WITH user_categories AS (
    SELECT DISTINCT p.category_id, COUNT(*) as cat_count
    FROM user_product_interactions upi JOIN products p ON p.id = upi.product_id
    WHERE upi.user_id = p_user_id AND upi.created_at > now() - interval '30 days'
    GROUP BY p.category_id
  ),
  user_viewed AS (
    SELECT DISTINCT upi.product_id FROM user_product_interactions upi
    WHERE upi.user_id = p_user_id AND upi.action_type = 'view' AND upi.created_at > now() - interval '7 days'
  )
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, p.category_id,
    (COALESCE(uc.cat_count, 0) * 10 +
     COALESCE((SELECT pps.popularity_score FROM product_popularity_scores pps WHERE pps.product_id = p.id), 0)::numeric * 0.5 +
     CASE WHEN p.is_featured THEN 20 ELSE 0 END + CASE WHEN p.is_hot THEN 15 ELSE 0 END
    )::numeric AS recommendation_score,
    CASE WHEN uc.cat_count > 3 THEN 'category_affinity' WHEN p.is_featured THEN 'featured' WHEN p.is_hot THEN 'trending' ELSE 'popular' END AS reason
  FROM products p LEFT JOIN user_categories uc ON uc.category_id = p.category_id
  WHERE p.is_active = true AND p.id NOT IN (SELECT uv.product_id FROM user_viewed uv)
  ORDER BY recommendation_score DESC LIMIT p_limit;
END; $$;

-- Fonction: Produits achetés ensemble
CREATE FUNCTION public.get_also_bought_products(p_product_id uuid, p_limit int DEFAULT 8)
RETURNS TABLE(product_id uuid, name text, price numeric, images text[], rating numeric, co_purchase_count int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, pcp.co_purchase_count
  FROM product_co_purchases pcp JOIN products p ON p.id = pcp.related_product_id
  WHERE pcp.product_id = p_product_id AND p.is_active = true
  ORDER BY pcp.co_purchase_count DESC LIMIT p_limit;
END; $$;

-- Fonction: Populaires par catégorie
CREATE FUNCTION public.get_popular_in_category(p_category_id uuid, p_limit int DEFAULT 10, p_exclude_product_id uuid DEFAULT NULL)
RETURNS TABLE(product_id uuid, name text, price numeric, images text[], rating numeric, popularity_score numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, COALESCE(pps.popularity_score, 0)::numeric
  FROM products p LEFT JOIN product_popularity_scores pps ON pps.product_id = p.id
  WHERE p.category_id = p_category_id AND p.is_active = true AND (p_exclude_product_id IS NULL OR p.id != p_exclude_product_id)
  ORDER BY COALESCE(pps.popularity_score, 0) DESC, p.rating DESC NULLS LAST LIMIT p_limit;
END; $$;

-- Trigger: popularité
CREATE FUNCTION public.update_popularity_on_interaction()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO product_popularity_scores (product_id, view_count, cart_count, purchase_count, popularity_score, updated_at)
  VALUES (NEW.product_id,
    CASE WHEN NEW.action_type = 'view' THEN 1 ELSE 0 END,
    CASE WHEN NEW.action_type = 'cart' THEN 1 ELSE 0 END,
    CASE WHEN NEW.action_type = 'purchase' THEN 1 ELSE 0 END,
    CASE WHEN NEW.action_type = 'view' THEN 1 WHEN NEW.action_type = 'cart' THEN 5 WHEN NEW.action_type = 'purchase' THEN 10 ELSE 0 END,
    now())
  ON CONFLICT (product_id) DO UPDATE SET
    view_count = product_popularity_scores.view_count + CASE WHEN NEW.action_type = 'view' THEN 1 ELSE 0 END,
    cart_count = product_popularity_scores.cart_count + CASE WHEN NEW.action_type = 'cart' THEN 1 ELSE 0 END,
    purchase_count = product_popularity_scores.purchase_count + CASE WHEN NEW.action_type = 'purchase' THEN 1 ELSE 0 END,
    popularity_score = product_popularity_scores.popularity_score + 
      CASE WHEN NEW.action_type = 'view' THEN 1 WHEN NEW.action_type = 'cart' THEN 5 WHEN NEW.action_type = 'purchase' THEN 10 ELSE 0 END,
    updated_at = now();
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_update_popularity ON public.user_product_interactions;
CREATE TRIGGER trg_update_popularity AFTER INSERT ON public.user_product_interactions FOR EACH ROW EXECUTE FUNCTION public.update_popularity_on_interaction();

-- Trigger: co-achats
CREATE FUNCTION public.update_co_purchases()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.action_type = 'purchase' THEN
    INSERT INTO product_co_purchases (product_id, related_product_id, co_purchase_count, updated_at)
    SELECT prev.product_id, NEW.product_id, 1, now()
    FROM user_product_interactions prev
    WHERE prev.user_id = NEW.user_id AND prev.action_type = 'purchase' AND prev.product_id != NEW.product_id AND prev.created_at > now() - interval '24 hours'
    ON CONFLICT (product_id, related_product_id) DO UPDATE SET co_purchase_count = product_co_purchases.co_purchase_count + 1, updated_at = now();
    INSERT INTO product_co_purchases (product_id, related_product_id, co_purchase_count, updated_at)
    SELECT NEW.product_id, prev.product_id, 1, now()
    FROM user_product_interactions prev
    WHERE prev.user_id = NEW.user_id AND prev.action_type = 'purchase' AND prev.product_id != NEW.product_id AND prev.created_at > now() - interval '24 hours'
    ON CONFLICT (product_id, related_product_id) DO UPDATE SET co_purchase_count = product_co_purchases.co_purchase_count + 1, updated_at = now();
  END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_update_co_purchases ON public.user_product_interactions;
CREATE TRIGGER trg_update_co_purchases AFTER INSERT ON public.user_product_interactions FOR EACH ROW EXECUTE FUNCTION public.update_co_purchases();
