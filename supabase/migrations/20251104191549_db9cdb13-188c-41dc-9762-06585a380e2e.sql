-- =========================================
-- SYSTÈME AUTOMATIQUE DE CRÉATION DE LIVRAISONS
-- Génère automatiquement des livraisons quand une commande est confirmée
-- =========================================

-- Fonction pour créer automatiquement une livraison quand une commande est confirmée
CREATE OR REPLACE FUNCTION public.create_delivery_for_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  vendor_address JSONB;
  shipping_addr JSONB;
  delivery_distance DECIMAL;
  delivery_cost DECIMAL;
BEGIN
  -- Ne créer une livraison que si la commande passe à "confirmed" ou "preparing"
  IF NEW.status IN ('confirmed', 'preparing') AND 
     (OLD.status IS NULL OR OLD.status NOT IN ('confirmed', 'preparing')) THEN
    
    -- Récupérer l'adresse du vendeur et la convertir en JSONB
    SELECT 
      CASE 
        WHEN v.address IS NOT NULL AND v.address != '' THEN 
          jsonb_build_object('address', v.address, 'lat', 9.509167, 'lng', -13.712222)
        ELSE '{"address": "Kaloum Market, Conakry, Guinée", "lat": 9.509167, "lng": -13.712222}'::jsonb
      END INTO vendor_address
    FROM vendors v
    WHERE v.id = NEW.vendor_id;
    
    -- Utiliser l'adresse de livraison de la commande ou une adresse par défaut
    shipping_addr := COALESCE(
      NEW.shipping_address,
      '{"address": "Ratoma, Conakry, Guinée", "lat": 9.577778, "lng": -13.659167}'::jsonb
    );
    
    -- Calculer la distance et le coût approximatif
    delivery_distance := CASE 
      WHEN NEW.total_amount > 200000 THEN 10.5
      WHEN NEW.total_amount > 100000 THEN 7.2
      ELSE 4.5
    END;
    
    delivery_cost := CASE 
      WHEN NEW.total_amount > 200000 THEN 15000
      WHEN NEW.total_amount > 100000 THEN 12000
      ELSE 8000
    END;
    
    -- Créer la livraison uniquement si elle n'existe pas déjà
    INSERT INTO public.deliveries (
      order_id,
      status,
      pickup_address,
      delivery_address,
      delivery_fee,
      distance_km,
      estimated_pickup_time,
      estimated_delivery_time,
      driver_notes
    )
    SELECT
      NEW.id,
      'pending'::delivery_status,
      vendor_address,
      shipping_addr,
      delivery_cost,
      delivery_distance,
      NOW() + INTERVAL '30 minutes',
      NOW() + INTERVAL '1 hour 30 minutes',
      'Livraison automatique - Commande ' || NEW.order_number
    WHERE NOT EXISTS (
      SELECT 1 FROM public.deliveries WHERE order_id = NEW.id
    );
    
  END IF;
  
  RETURN NEW;
END;
$$;

-- Créer le trigger sur la table orders
DROP TRIGGER IF EXISTS auto_create_delivery_on_order_confirmed ON public.orders;
CREATE TRIGGER auto_create_delivery_on_order_confirmed
  AFTER INSERT OR UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.create_delivery_for_order();

-- Mettre à jour les livraisons existantes avec de vraies adresses de Conakry
UPDATE public.deliveries
SET 
  pickup_address = CASE 
    WHEN (pickup_address->>'address') = 'Point de vente' 
    THEN '{"address": "Kaloum Market, Conakry, Guinée", "lat": 9.509167, "lng": -13.712222}'::jsonb
    ELSE pickup_address
  END,
  delivery_address = CASE
    WHEN (delivery_address->>'address') = 'Point de vente' 
    THEN CASE (random() * 5)::int
      WHEN 0 THEN '{"address": "Ratoma, Conakry, Guinée", "lat": 9.577778, "lng": -13.659167}'::jsonb
      WHEN 1 THEN '{"address": "Camayenne, Conakry, Guinée", "lat": 9.535833, "lng": -13.688333}'::jsonb
      WHEN 2 THEN '{"address": "Hamdallaye, Conakry, Guinée", "lat": 9.551944, "lng": -13.670556}'::jsonb
      WHEN 3 THEN '{"address": "Matam, Conakry, Guinée", "lat": 9.515556, "lng": -13.667222}'::jsonb
      WHEN 4 THEN '{"address": "Dixinn, Conakry, Guinée", "lat": 9.553611, "lng": -13.679444}'::jsonb
      ELSE '{"address": "Madina, Conakry, Guinée", "lat": 9.537222, "lng": -13.687778}'::jsonb
    END
    ELSE delivery_address
  END,
  driver_notes = 'Livraison avec adresses réelles de Conakry'
WHERE status = 'pending'
  AND ((pickup_address->>'address') = 'Point de vente' OR (delivery_address->>'address') = 'Point de vente');