-- 🚴 CRÉER LE PROFIL DRIVER POUR L'UTILISATEUR LIVREUR
-- Et créer des livraisons réelles liées aux commandes existantes

-- Créer le profil driver pour l'utilisateur livreur actuel
INSERT INTO drivers (
  user_id,
  license_number,
  vehicle_type,
  vehicle_info,
  is_online,
  is_verified,
  rating,
  total_deliveries
) VALUES (
  '6f34c07a-6d9a-4dbc-b92f-e95769eb1ff2',
  'DRV-GN-2025-001',
  'moto',
  '{"marque": "Honda", "modele": "XR 150", "annee": 2023, "couleur": "Rouge"}'::jsonb,
  true,
  true,
  5.0,
  0
)
ON CONFLICT (user_id) DO UPDATE SET
  is_verified = true,
  is_online = true;

-- Créer des livraisons réelles pour les commandes confirmées existantes
INSERT INTO deliveries (
  order_id,
  status,
  pickup_address,
  delivery_address,
  delivery_fee,
  distance_km,
  estimated_pickup_time,
  estimated_delivery_time,
  driver_id
)
SELECT 
  o.id,
  'pending'::delivery_status,
  COALESCE(
    o.shipping_address,
    '{"address": "Kaloum Market, Conakry", "lat": 9.509167, "lng": -13.712222}'::jsonb
  ),
  o.shipping_address,
  CASE 
    WHEN o.total_amount > 200000 THEN 15000
    WHEN o.total_amount > 100000 THEN 12000
    ELSE 8000
  END,
  CASE 
    WHEN o.total_amount > 200000 THEN 10.5
    WHEN o.total_amount > 100000 THEN 7.2
    ELSE 4.5
  END,
  now() + interval '30 minutes',
  now() + interval '1 hour 30 minutes',
  NULL
FROM orders o
WHERE o.status IN ('confirmed', 'preparing')
AND NOT EXISTS (
  SELECT 1 FROM deliveries d WHERE d.order_id = o.id
)
LIMIT 5
ON CONFLICT DO NOTHING;

-- Mettre à jour les livraisons de test pour qu'elles soient valides
UPDATE deliveries
SET 
  pickup_address = CASE 
    WHEN pickup_address::text = 'null' THEN '{"address": "Kaloum, Conakry", "lat": 9.509167, "lng": -13.712222}'::jsonb
    ELSE pickup_address
  END,
  delivery_address = CASE
    WHEN delivery_address::text = 'null' THEN '{"address": "Ratoma, Conakry", "lat": 9.577778, "lng": -13.659167}'::jsonb
    ELSE delivery_address
  END,
  delivery_fee = COALESCE(delivery_fee, 10000),
  distance_km = COALESCE(distance_km, 5.0)
WHERE status = 'pending';
