-- Mettre à jour rating/reviews_count des produits à partir des avis vendeur (vendor_ratings)

CREATE OR REPLACE FUNCTION public.update_products_rating_from_vendor_ratings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendor_id uuid;
  avg_rating numeric;
  total_reviews integer;
BEGIN
  v_vendor_id := COALESCE(NEW.vendor_id, OLD.vendor_id);

  -- Agréger les notes pour ce vendeur
  SELECT
    COALESCE(AVG(rating)::numeric(3,2), 0),
    COALESCE(COUNT(*), 0)
  INTO avg_rating, total_reviews
  FROM public.vendor_ratings
  WHERE vendor_id = v_vendor_id;

  -- Appliquer ces stats sur tous les produits de ce vendeur
  UPDATE public.products
  SET
    rating = avg_rating,
    reviews_count = total_reviews
  WHERE vendor_id = v_vendor_id;

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Triggers sur vendor_ratings
DROP TRIGGER IF EXISTS trigger_update_products_rating_from_vendor_ratings_insert ON public.vendor_ratings;
CREATE TRIGGER trigger_update_products_rating_from_vendor_ratings_insert
AFTER INSERT ON public.vendor_ratings
FOR EACH ROW
EXECUTE FUNCTION public.update_products_rating_from_vendor_ratings();

DROP TRIGGER IF EXISTS trigger_update_products_rating_from_vendor_ratings_update ON public.vendor_ratings;
CREATE TRIGGER trigger_update_products_rating_from_vendor_ratings_update
AFTER UPDATE ON public.vendor_ratings
FOR EACH ROW
EXECUTE FUNCTION public.update_products_rating_from_vendor_ratings();

DROP TRIGGER IF EXISTS trigger_update_products_rating_from_vendor_ratings_delete ON public.vendor_ratings;
CREATE TRIGGER trigger_update_products_rating_from_vendor_ratings_delete
AFTER DELETE ON public.vendor_ratings
FOR EACH ROW
EXECUTE FUNCTION public.update_products_rating_from_vendor_ratings();

-- Backfill: recalculer pour tous les vendeurs ayant des avis
WITH stats AS (
  SELECT
    vendor_id,
    AVG(rating)::numeric(3,2) AS avg_rating,
    COUNT(*)::int AS review_count
  FROM public.vendor_ratings
  GROUP BY vendor_id
)
UPDATE public.products p
SET
  rating = COALESCE(s.avg_rating, 0),
  reviews_count = COALESCE(s.review_count, 0)
FROM stats s
WHERE p.vendor_id = s.vendor_id;