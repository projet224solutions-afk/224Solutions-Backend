-- 🔧 CORRIGER LES POLITIQUES RLS POUR LES LIVREURS
-- Permettre aux livreurs de voir les livraisons disponibles (pending) ET leurs propres livraisons

-- Supprimer l'ancienne politique restrictive
DROP POLICY IF EXISTS "Drivers can view their deliveries" ON deliveries;

-- Nouvelle politique: Les livreurs peuvent voir les livraisons pending OU leurs propres livraisons
CREATE POLICY "Drivers can view available and assigned deliveries"
ON deliveries FOR SELECT
USING (
  status = 'pending' OR auth.uid() = driver_id
);

-- S'assurer que les livreurs peuvent accepter les livraisons pending
DROP POLICY IF EXISTS "Drivers can update their deliveries" ON deliveries;

CREATE POLICY "Drivers can accept and update deliveries"
ON deliveries FOR UPDATE
USING (
  (status = 'pending' AND driver_id IS NULL) OR 
  (auth.uid() = driver_id)
);

-- Insérer quelques livraisons de test pour les livreurs
INSERT INTO deliveries (
  order_id,
  status,
  pickup_address,
  delivery_address,
  delivery_fee,
  distance_km,
  estimated_pickup_time,
  estimated_delivery_time
) VALUES 
(
  (SELECT id FROM orders LIMIT 1),
  'pending',
  '{"address": "Kaloum, Conakry, Guinée", "lat": 9.509167, "lng": -13.712222}'::jsonb,
  '{"address": "Ratoma, Conakry, Guinée", "lat": 9.577778, "lng": -13.659167}'::jsonb,
  15000,
  8.5,
  now() + interval '30 minutes',
  now() + interval '1 hour'
),
(
  (SELECT id FROM orders LIMIT 1 OFFSET 1),
  'pending',
  '{"address": "Madina, Conakry, Guinée", "lat": 9.537222, "lng": -13.687778}'::jsonb,
  '{"address": "Camayenne, Conakry, Guinée", "lat": 9.535833, "lng": -13.688333}'::jsonb,
  12000,
  5.2,
  now() + interval '20 minutes',
  now() + interval '50 minutes'
),
(
  (SELECT id FROM orders LIMIT 1 OFFSET 2),
  'pending',
  '{"address": "Matam, Conakry, Guinée", "lat": 9.515556, "lng": -13.667222}'::jsonb,
  '{"address": "Hamdallaye, Conakry, Guinée", "lat": 9.551944, "lng": -13.670556}'::jsonb,
  18000,
  12.3,
  now() + interval '45 minutes',
  now() + interval '1 hour 30 minutes'
)
ON CONFLICT DO NOTHING;
