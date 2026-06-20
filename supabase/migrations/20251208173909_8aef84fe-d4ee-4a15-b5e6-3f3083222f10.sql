-- Désactiver le trigger qui crée automatiquement des livraisons incomplètes
DROP TRIGGER IF EXISTS auto_create_delivery_on_order_confirmed ON public.orders;

-- Supprimer les livraisons de test/automatiques sans données valides
DELETE FROM deliveries 
WHERE status = 'pending' 
  AND driver_id IS NULL 
  AND (vendor_id IS NULL OR customer_name IS NULL OR vendor_name IS NULL);

-- Créer un nouveau trigger plus intelligent qui ne crée des livraisons que si les données sont complètes
CREATE OR REPLACE FUNCTION public.create_delivery_for_order_v2()
RETURNS TRIGGER AS $$
DECLARE
  vendor_data RECORD;
  customer_data RECORD;
  delivery_distance DECIMAL;
  delivery_cost DECIMAL;
BEGIN
  -- Ne créer une livraison que si la commande passe à "confirmed" ou "preparing"
  IF NEW.status IN ('confirmed', 'preparing') AND 
     (OLD IS NULL OR OLD.status NOT IN ('confirmed', 'preparing')) THEN
    
    -- Vérifier que nous avons un vendor_id valide
    IF NEW.vendor_id IS NULL THEN
      RETURN NEW;
    END IF;
    
    -- Récupérer les données du vendeur
    SELECT v.id, v.business_name, v.phone, p.full_name, p.email,
           v.business_address
    INTO vendor_data
    FROM vendors v
    LEFT JOIN profiles p ON v.user_id = p.id
    WHERE v.id = NEW.vendor_id;
    
    IF NOT FOUND OR vendor_data.business_name IS NULL THEN
      RETURN NEW;
    END IF;
    
    -- Vérifier que nous avons une adresse de livraison valide
    IF NEW.shipping_address IS NULL OR NEW.shipping_address = '{}'::jsonb THEN
      RETURN NEW;
    END IF;
    
    -- Vérifier les coordonnées dans l'adresse de livraison
    IF (NEW.shipping_address->>'lat') IS NULL OR (NEW.shipping_address->>'lng') IS NULL THEN
      RETURN NEW;
    END IF;
    
    -- Récupérer les données du client (optionnel mais préférable)
    SELECT p.full_name, p.phone, p.email
    INTO customer_data
    FROM profiles p
    WHERE p.id = NEW.customer_id;
    
    -- Calculer la distance (simple estimation si pas de coordonnées vendeur)
    delivery_distance := 5.0; -- Distance par défaut
    delivery_cost := 8000; -- Coût par défaut en GNF
    
    -- Vérifier qu'une livraison n'existe pas déjà pour cette commande
    IF EXISTS (SELECT 1 FROM deliveries WHERE order_id = NEW.id) THEN
      RETURN NEW;
    END IF;
    
    -- Créer la livraison avec toutes les données nécessaires
    INSERT INTO deliveries (
      order_id,
      vendor_id,
      vendor_name,
      vendor_phone,
      customer_name,
      customer_phone,
      pickup_address,
      delivery_address,
      status,
      delivery_fee,
      distance_km,
      package_description,
      created_at
    ) VALUES (
      NEW.id,
      NEW.vendor_id,
      vendor_data.business_name,
      vendor_data.phone,
      COALESCE(customer_data.full_name, NEW.shipping_address->>'name', 'Client'),
      COALESCE(customer_data.phone, NEW.shipping_address->>'phone'),
      jsonb_build_object(
        'address', COALESCE(vendor_data.business_address, 'Adresse vendeur'),
        'lat', 9.509167,
        'lng', -13.712222
      ),
      NEW.shipping_address,
      'pending',
      delivery_cost,
      delivery_distance,
      'Commande #' || COALESCE(NEW.public_id, NEW.id::text),
      NOW()
    );
  END IF;
  
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- En cas d'erreur, ne pas bloquer la commande
    RAISE NOTICE 'Erreur création livraison: %', SQLERRM;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- NE PAS recréer le trigger automatique - les livraisons doivent être créées explicitement par le vendeur
-- Si vous voulez réactiver plus tard:
-- CREATE TRIGGER auto_create_delivery_on_order_confirmed
--   AFTER INSERT OR UPDATE ON public.orders
--   FOR EACH ROW
--   EXECUTE FUNCTION create_delivery_for_order_v2();