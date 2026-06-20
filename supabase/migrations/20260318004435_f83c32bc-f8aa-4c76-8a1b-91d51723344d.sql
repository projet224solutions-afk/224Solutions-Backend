
-- Update trigger to use interaction_type column instead of action_type
CREATE OR REPLACE FUNCTION public.update_popularity_on_interaction()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO product_popularity_scores (product_id, view_count, cart_count, purchase_count, popularity_score, updated_at)
  VALUES (NEW.product_id,
    CASE WHEN NEW.interaction_type = 'view' THEN 1 ELSE 0 END,
    CASE WHEN NEW.interaction_type = 'cart' THEN 1 ELSE 0 END,
    CASE WHEN NEW.interaction_type = 'purchase' THEN 1 ELSE 0 END,
    CASE WHEN NEW.interaction_type = 'view' THEN 1 WHEN NEW.interaction_type = 'cart' THEN 5 WHEN NEW.interaction_type = 'purchase' THEN 10 ELSE 0 END,
    now())
  ON CONFLICT (product_id) DO UPDATE SET
    view_count = product_popularity_scores.view_count + CASE WHEN NEW.interaction_type = 'view' THEN 1 ELSE 0 END,
    cart_count = product_popularity_scores.cart_count + CASE WHEN NEW.interaction_type = 'cart' THEN 1 ELSE 0 END,
    purchase_count = product_popularity_scores.purchase_count + CASE WHEN NEW.interaction_type = 'purchase' THEN 1 ELSE 0 END,
    popularity_score = product_popularity_scores.popularity_score + 
      CASE WHEN NEW.interaction_type = 'view' THEN 1 WHEN NEW.interaction_type = 'cart' THEN 5 WHEN NEW.interaction_type = 'purchase' THEN 10 ELSE 0 END,
    updated_at = now();
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.update_co_purchases()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.interaction_type = 'purchase' THEN
    INSERT INTO product_co_purchases (product_id, related_product_id, co_purchase_count, updated_at)
    SELECT prev.product_id, NEW.product_id, 1, now()
    FROM user_product_interactions prev
    WHERE prev.user_id = NEW.user_id AND prev.interaction_type = 'purchase' AND prev.product_id != NEW.product_id AND prev.created_at > now() - interval '24 hours'
    ON CONFLICT (product_id, related_product_id) DO UPDATE SET co_purchase_count = product_co_purchases.co_purchase_count + 1, updated_at = now();
    INSERT INTO product_co_purchases (product_id, related_product_id, co_purchase_count, updated_at)
    SELECT NEW.product_id, prev.product_id, 1, now()
    FROM user_product_interactions prev
    WHERE prev.user_id = NEW.user_id AND prev.interaction_type = 'purchase' AND prev.product_id != NEW.product_id AND prev.created_at > now() - interval '24 hours'
    ON CONFLICT (product_id, related_product_id) DO UPDATE SET co_purchase_count = product_co_purchases.co_purchase_count + 1, updated_at = now();
  END IF;
  RETURN NEW;
END; $$;

-- Update personalized recommendations to use interaction_type
CREATE OR REPLACE FUNCTION public.get_personalized_recommendations(p_user_id uuid, p_limit int DEFAULT 12)
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
    WHERE upi.user_id = p_user_id AND upi.interaction_type = 'view' AND upi.created_at > now() - interval '7 days'
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
