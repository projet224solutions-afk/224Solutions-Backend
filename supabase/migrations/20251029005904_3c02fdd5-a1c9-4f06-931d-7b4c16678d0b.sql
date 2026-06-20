
-- 🚴 CRÉER PROFIL TAXI_DRIVER ET UNIFIER LE SYSTÈME
-- Créer le profil taxi_driver pour l'utilisateur livreur

INSERT INTO taxi_drivers (
  user_id,
  vehicle_type,
  vehicle_plate,
  vehicle,
  last_lat,
  last_lng,
  is_online,
  kyc_verified,
  can_work,
  rating,
  status
) VALUES (
  '6f34c07a-6d9a-4dbc-b92f-e95769eb1ff2',
  'moto',
  'C-224-GN',
  '{"brand": "Honda", "model": "XR 150", "year": 2023, "color": "Rouge"}'::jsonb,
  9.509167,
  -13.712222,
  true,
  true,
  true,
  5.0,
  'online'
)
ON CONFLICT (user_id) DO UPDATE SET
  kyc_verified = true,
  can_work = true,
  is_online = true,
  status = 'online';
