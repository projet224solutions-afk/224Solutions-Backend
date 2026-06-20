-- Supprimer les anciens triggers basés sur vendor_ratings
DROP TRIGGER IF EXISTS sync_vendor_rating_to_products_insert ON vendor_ratings;
DROP TRIGGER IF EXISTS sync_vendor_rating_to_products_update ON vendor_ratings;
DROP TRIGGER IF EXISTS sync_vendor_rating_to_products_delete ON vendor_ratings;
DROP FUNCTION IF EXISTS update_product_ratings_from_vendor();

-- Réinitialiser les notes des produits (seuls ceux avec des avis auront une note)
UPDATE products SET rating = NULL, reviews_count = 0, updated_at = NOW();

-- Nouvelle fonction pour synchroniser les avis produits spécifiques
CREATE OR REPLACE FUNCTION public.sync_product_rating()
RETURNS TRIGGER AS $$
DECLARE
  avg_rating NUMERIC;
  total_reviews INTEGER;
  target_product_id UUID;
BEGIN
  -- Déterminer le product_id concerné
  target_product_id := COALESCE(NEW.product_id, OLD.product_id);
  
  -- Calculer la moyenne des notes et le nombre d'avis pour CE produit uniquement
  SELECT 
    COALESCE(AVG(rating), NULL),
    COUNT(*)
  INTO avg_rating, total_reviews
  FROM product_reviews
  WHERE product_id = target_product_id
    AND is_approved = true;
  
  -- Mettre à jour uniquement CE produit
  UPDATE products
  SET 
    rating = CASE WHEN total_reviews > 0 THEN ROUND(avg_rating, 2) ELSE NULL END,
    reviews_count = total_reviews,
    updated_at = NOW()
  WHERE id = target_product_id;
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Triggers sur product_reviews (avis spécifiques aux produits)
CREATE TRIGGER sync_product_rating_insert
AFTER INSERT ON product_reviews
FOR EACH ROW
EXECUTE FUNCTION sync_product_rating();

CREATE TRIGGER sync_product_rating_update
AFTER UPDATE ON product_reviews
FOR EACH ROW
EXECUTE FUNCTION sync_product_rating();

CREATE TRIGGER sync_product_rating_delete
AFTER DELETE ON product_reviews
FOR EACH ROW
EXECUTE FUNCTION sync_product_rating();

-- Synchroniser les avis existants pour les produits qui en ont
DO $$
DECLARE
  p_record RECORD;
  avg_rating NUMERIC;
  total_reviews INTEGER;
BEGIN
  FOR p_record IN SELECT DISTINCT product_id FROM product_reviews WHERE is_approved = true LOOP
    SELECT 
      COALESCE(AVG(rating), NULL),
      COUNT(*)
    INTO avg_rating, total_reviews
    FROM product_reviews
    WHERE product_id = p_record.product_id
      AND is_approved = true;
    
    UPDATE products
    SET 
      rating = CASE WHEN total_reviews > 0 THEN ROUND(avg_rating, 2) ELSE NULL END,
      reviews_count = total_reviews,
      updated_at = NOW()
    WHERE id = p_record.product_id;
  END LOOP;
END $$;