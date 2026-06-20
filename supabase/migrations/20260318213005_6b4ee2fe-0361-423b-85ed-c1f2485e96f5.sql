-- Drop existing functions first to allow return type changes
DROP FUNCTION IF EXISTS public.get_personalized_recommendations(uuid, integer);
DROP FUNCTION IF EXISTS public.get_similar_products(uuid, integer);
DROP FUNCTION IF EXISTS public.get_also_bought_products(uuid, integer);
DROP FUNCTION IF EXISTS public.get_popular_in_category(uuid, integer, uuid);
DROP FUNCTION IF EXISTS public.generate_recommendations_for_user(uuid, integer);

-- 1. get_personalized_recommendations - avec filtre vendeur vente en ligne
CREATE OR REPLACE FUNCTION public.get_personalized_recommendations(p_user_id uuid, p_limit integer DEFAULT 12)
RETURNS TABLE(id uuid, name text, price numeric, images jsonb, rating numeric, category_id uuid, recommendation_score numeric, reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
    WHERE upi.user_id = p_user_id AND upi.interaction_type = 'view' AND upi.created_at > now() - interval '7 days'
  )
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, p.category_id,
    (COALESCE(uc.cat_count, 0) * 10 +
     COALESCE((SELECT pps.popularity_score FROM product_popularity_scores pps WHERE pps.product_id = p.id), 0)::numeric * 0.5 +
     CASE WHEN p.is_featured THEN 20 ELSE 0 END + CASE WHEN p.is_hot THEN 15 ELSE 0 END
    )::numeric AS recommendation_score,
    CASE WHEN uc.cat_count > 3 THEN 'category_affinity' WHEN p.is_featured THEN 'featured' WHEN p.is_hot THEN 'trending' ELSE 'popular' END AS reason
  FROM products p 
  LEFT JOIN user_categories uc ON uc.category_id = p.category_id
  JOIN vendors v ON v.id = p.vendor_id
  WHERE p.is_active = true 
    AND v.business_type IN ('hybrid', 'online')
    AND p.id NOT IN (SELECT uv.product_id FROM user_viewed uv)
  ORDER BY recommendation_score DESC LIMIT p_limit;
END;
$$;

-- 2. get_similar_products - avec filtre vendeur vente en ligne
CREATE OR REPLACE FUNCTION public.get_similar_products(p_product_id uuid, p_limit integer DEFAULT 10)
RETURNS TABLE(id uuid, name text, price numeric, images jsonb, rating numeric, category_id uuid, similarity_score numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
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
  JOIN vendors v ON v.id = p.vendor_id
  WHERE p.id != p_product_id AND p.is_active = true
    AND v.business_type IN ('hybrid', 'online')
    AND (p.category_id = v_category_id OR (p.tags IS NOT NULL AND v_tags IS NOT NULL AND p.tags && v_tags))
  ORDER BY similarity_score DESC LIMIT p_limit;
END;
$$;

-- 3. get_also_bought_products - avec filtre vendeur vente en ligne
CREATE OR REPLACE FUNCTION public.get_also_bought_products(p_product_id uuid, p_limit integer DEFAULT 8)
RETURNS TABLE(id uuid, name text, price numeric, images jsonb, rating numeric, co_purchase_count bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, pcp.co_purchase_count
  FROM product_co_purchases pcp 
  JOIN products p ON p.id = pcp.related_product_id
  JOIN vendors v ON v.id = p.vendor_id
  WHERE pcp.product_id = p_product_id AND p.is_active = true
    AND v.business_type IN ('hybrid', 'online')
  ORDER BY pcp.co_purchase_count DESC LIMIT p_limit;
END;
$$;

-- 4. get_popular_in_category - avec filtre vendeur vente en ligne
CREATE OR REPLACE FUNCTION public.get_popular_in_category(p_category_id uuid, p_limit integer DEFAULT 10, p_exclude_product_id uuid DEFAULT NULL)
RETURNS TABLE(id uuid, name text, price numeric, images jsonb, rating numeric, popularity numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.name, p.price::numeric, p.images, p.rating, COALESCE(pps.popularity_score, 0)::numeric
  FROM products p 
  LEFT JOIN product_popularity_scores pps ON pps.product_id = p.id
  JOIN vendors v ON v.id = p.vendor_id
  WHERE p.category_id = p_category_id AND p.is_active = true 
    AND v.business_type IN ('hybrid', 'online')
    AND (p_exclude_product_id IS NULL OR p.id != p_exclude_product_id)
  ORDER BY COALESCE(pps.popularity_score, 0) DESC, p.rating DESC NULLS LAST LIMIT p_limit;
END;
$$;

-- 5. generate_recommendations_for_user - avec filtre vendeur vente en ligne
CREATE OR REPLACE FUNCTION public.generate_recommendations_for_user(p_user_id uuid, p_limit integer DEFAULT 10)
RETURNS TABLE(product_id uuid, score numeric, reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
BEGIN
    DELETE FROM product_recommendations
    WHERE user_id = p_user_id
    AND expires_at < NOW();

    RETURN QUERY
    SELECT DISTINCT
        p.id as product_id,
        0.8::DECIMAL as score,
        'Basé sur votre historique'::text as reason
    FROM products p
    JOIN vendors v ON v.id = p.vendor_id
    WHERE p.id IN (
        SELECT DISTINCT pv.product_id
        FROM product_views pv
        WHERE pv.user_id = p_user_id
        AND pv.viewed_at > NOW() - INTERVAL '30 days'
        ORDER BY pv.viewed_at DESC
        LIMIT 5
    )
    AND p.stock_quantity > 0
    AND v.business_type IN ('hybrid', 'online')
    LIMIT p_limit;
END;
$$;

-- 6. Invalider le cache des recommandations IA (mettre expires_at dans le passé)
UPDATE ai_recommendations_cache SET expires_at = now() - interval '1 hour' WHERE expires_at > now();