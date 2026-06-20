-- Fonction pour mettre à jour le rating et reviews_count d'un produit
CREATE OR REPLACE FUNCTION update_product_rating()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  avg_rating NUMERIC;
  total_reviews INTEGER;
BEGIN
  -- Calculer la moyenne des notes et le nombre d'avis approuvés
  SELECT 
    COALESCE(AVG(rating)::NUMERIC(3,2), 0),
    COALESCE(COUNT(*), 0)
  INTO avg_rating, total_reviews
  FROM product_reviews
  WHERE product_id = COALESCE(NEW.product_id, OLD.product_id)
    AND is_approved = true;

  -- Mettre à jour le produit
  UPDATE products
  SET 
    rating = avg_rating,
    reviews_count = total_reviews
  WHERE id = COALESCE(NEW.product_id, OLD.product_id);

  RETURN COALESCE(NEW, OLD);
END;
$$;

-- Trigger après INSERT
DROP TRIGGER IF EXISTS trigger_update_product_rating_insert ON product_reviews;
CREATE TRIGGER trigger_update_product_rating_insert
AFTER INSERT ON product_reviews
FOR EACH ROW
EXECUTE FUNCTION update_product_rating();

-- Trigger après UPDATE (ex: is_approved change)
DROP TRIGGER IF EXISTS trigger_update_product_rating_update ON product_reviews;
CREATE TRIGGER trigger_update_product_rating_update
AFTER UPDATE ON product_reviews
FOR EACH ROW
EXECUTE FUNCTION update_product_rating();

-- Trigger après DELETE
DROP TRIGGER IF EXISTS trigger_update_product_rating_delete ON product_reviews;
CREATE TRIGGER trigger_update_product_rating_delete
AFTER DELETE ON product_reviews
FOR EACH ROW
EXECUTE FUNCTION update_product_rating();

-- Mettre à jour tous les produits existants avec les stats actuelles (si des avis existaient)
UPDATE products p
SET 
  rating = COALESCE(stats.avg_rating, 0),
  reviews_count = COALESCE(stats.review_count, 0)
FROM (
  SELECT 
    product_id,
    AVG(rating)::NUMERIC(3,2) as avg_rating,
    COUNT(*) as review_count
  FROM product_reviews
  WHERE is_approved = true
  GROUP BY product_id
) stats
WHERE p.id = stats.product_id;