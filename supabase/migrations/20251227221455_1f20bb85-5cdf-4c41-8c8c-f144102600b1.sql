-- Fix: avis par produit (product_reviews) au lieu d'avis vendeur (vendor_ratings)

-- 1) Stopper la mise à jour des produits via vendor_ratings
DROP TRIGGER IF EXISTS trigger_update_products_rating_from_vendor_ratings_insert ON public.vendor_ratings;
DROP TRIGGER IF EXISTS trigger_update_products_rating_from_vendor_ratings_update ON public.vendor_ratings;
DROP TRIGGER IF EXISTS trigger_update_products_rating_from_vendor_ratings_delete ON public.vendor_ratings;
DROP FUNCTION IF EXISTS public.update_products_rating_from_vendor_ratings();

-- 2) Créer index unique COMPLET (non-partiel) pour empêcher les doublons
CREATE UNIQUE INDEX IF NOT EXISTS product_reviews_unique_user_product
  ON public.product_reviews (user_id, product_id);

-- 3) Fonction + triggers: recalculer rating/reviews_count PAR PRODUIT à chaque changement de product_reviews
CREATE OR REPLACE FUNCTION public.update_product_rating_from_product_reviews()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product_id uuid;
  avg_rating numeric;
  total_reviews integer;
BEGIN
  v_product_id := COALESCE(NEW.product_id, OLD.product_id);

  SELECT
    COALESCE(AVG(rating)::numeric(3,2), 0),
    COALESCE(COUNT(*)::int, 0)
  INTO avg_rating, total_reviews
  FROM public.product_reviews
  WHERE product_id = v_product_id
    AND is_approved = true;

  UPDATE public.products
  SET rating = avg_rating,
      reviews_count = total_reviews
  WHERE id = v_product_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trigger_update_product_rating_from_product_reviews_insert ON public.product_reviews;
CREATE TRIGGER trigger_update_product_rating_from_product_reviews_insert
AFTER INSERT ON public.product_reviews
FOR EACH ROW
EXECUTE FUNCTION public.update_product_rating_from_product_reviews();

DROP TRIGGER IF EXISTS trigger_update_product_rating_from_product_reviews_update ON public.product_reviews;
CREATE TRIGGER trigger_update_product_rating_from_product_reviews_update
AFTER UPDATE ON public.product_reviews
FOR EACH ROW
EXECUTE FUNCTION public.update_product_rating_from_product_reviews();

DROP TRIGGER IF EXISTS trigger_update_product_rating_from_product_reviews_delete ON public.product_reviews;
CREATE TRIGGER trigger_update_product_rating_from_product_reviews_delete
AFTER DELETE ON public.product_reviews
FOR EACH ROW
EXECUTE FUNCTION public.update_product_rating_from_product_reviews();

-- 4) Backfill: convertir les avis existants (vendor_ratings) en avis produit (product_reviews)
--    (1 avis vendeur -> 1 avis par produit de la commande)
INSERT INTO public.product_reviews (
  product_id,
  user_id,
  order_id,
  rating,
  title,
  content,
  verified_purchase,
  is_approved,
  created_at,
  updated_at
)
SELECT DISTINCT ON (oi.product_id, vr.customer_id)
  oi.product_id,
  vr.customer_id AS user_id,
  vr.order_id,
  vr.rating,
  'Avis client' AS title,
  COALESCE(vr.comment, '') AS content,
  true AS verified_purchase,
  true AS is_approved,
  vr.created_at,
  COALESCE(vr.updated_at, vr.created_at)
FROM public.vendor_ratings vr
JOIN public.order_items oi ON oi.order_id = vr.order_id
WHERE vr.order_id IS NOT NULL
ORDER BY oi.product_id, vr.customer_id, vr.created_at DESC
ON CONFLICT (user_id, product_id) DO NOTHING;

-- 5) Backfill rating/reviews_count pour tous les produits ayant des avis
WITH stats AS (
  SELECT
    product_id,
    AVG(rating)::numeric(3,2) AS avg_rating,
    COUNT(*)::int AS review_count
  FROM public.product_reviews
  WHERE is_approved = true
  GROUP BY product_id
)
UPDATE public.products p
SET
  rating = COALESCE(s.avg_rating, 0),
  reviews_count = COALESCE(s.review_count, 0)
FROM stats s
WHERE p.id = s.product_id;

-- 6) Remettre à zéro les produits sans avis
UPDATE public.products p
SET rating = 0,
    reviews_count = 0
WHERE NOT EXISTS (
  SELECT 1
  FROM public.product_reviews pr
  WHERE pr.product_id = p.id
    AND pr.is_approved = true
);
