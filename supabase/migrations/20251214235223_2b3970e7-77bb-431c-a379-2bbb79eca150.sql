-- Fonction pour mettre à jour les notes des produits à partir des avis vendeur
CREATE OR REPLACE FUNCTION public.update_product_ratings_from_vendor()
RETURNS TRIGGER AS $$
DECLARE
  avg_rating NUMERIC;
  total_reviews INTEGER;
BEGIN
  -- Calculer la moyenne des notes et le nombre total d'avis pour ce vendeur
  SELECT 
    COALESCE(AVG(rating), 0),
    COUNT(*)
  INTO avg_rating, total_reviews
  FROM vendor_ratings
  WHERE vendor_id = COALESCE(NEW.vendor_id, OLD.vendor_id);
  
  -- Mettre à jour tous les produits de ce vendeur avec la note moyenne
  UPDATE products
  SET 
    rating = ROUND(avg_rating, 2),
    reviews_count = total_reviews,
    updated_at = NOW()
  WHERE vendor_id = COALESCE(NEW.vendor_id, OLD.vendor_id);
  
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Trigger après insertion d'un avis
DROP TRIGGER IF EXISTS sync_vendor_rating_to_products_insert ON vendor_ratings;
CREATE TRIGGER sync_vendor_rating_to_products_insert
AFTER INSERT ON vendor_ratings
FOR EACH ROW
EXECUTE FUNCTION update_product_ratings_from_vendor();

-- Trigger après mise à jour d'un avis
DROP TRIGGER IF EXISTS sync_vendor_rating_to_products_update ON vendor_ratings;
CREATE TRIGGER sync_vendor_rating_to_products_update
AFTER UPDATE ON vendor_ratings
FOR EACH ROW
EXECUTE FUNCTION update_product_ratings_from_vendor();

-- Trigger après suppression d'un avis
DROP TRIGGER IF EXISTS sync_vendor_rating_to_products_delete ON vendor_ratings;
CREATE TRIGGER sync_vendor_rating_to_products_delete
AFTER DELETE ON vendor_ratings
FOR EACH ROW
EXECUTE FUNCTION update_product_ratings_from_vendor();

-- Synchroniser les notes existantes pour tous les vendeurs
DO $$
DECLARE
  v_record RECORD;
  avg_rating NUMERIC;
  total_reviews INTEGER;
BEGIN
  FOR v_record IN SELECT DISTINCT vendor_id FROM vendor_ratings LOOP
    SELECT 
      COALESCE(AVG(rating), 0),
      COUNT(*)
    INTO avg_rating, total_reviews
    FROM vendor_ratings
    WHERE vendor_id = v_record.vendor_id;
    
    UPDATE products
    SET 
      rating = ROUND(avg_rating, 2),
      reviews_count = total_reviews,
      updated_at = NOW()
    WHERE vendor_id = v_record.vendor_id;
  END LOOP;
END $$;