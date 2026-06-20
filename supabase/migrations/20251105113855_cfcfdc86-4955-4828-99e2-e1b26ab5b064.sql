-- Créer une livraison de test assignée à Thierno Bah
INSERT INTO deliveries (
  order_id,
  driver_id,
  client_id,
  status,
  pickup_address,
  delivery_address,
  delivery_fee,
  distance_km,
  driver_notes
) VALUES (
  'b31e58ad-b62d-4c9e-b622-aa427c0d7b0d',  -- Order ID existant
  '6f34c07a-6d9a-4dbc-b92f-e95769eb1ff2',  -- Profile ID de Thierno Bah
  '6f34c07a-6d9a-4dbc-b92f-e95769eb1ff2',  -- Client ID (même utilisateur pour test)
  'picked_up',  -- Statut pour qu'elle apparaisse comme active
  '{"address": "Restaurant Le Gourmet, Kaloum, Conakry", "lat": 9.509167, "lng": -13.712222}',
  '{"address": "Résidence Avenue, Ratoma, Conakry", "lat": 9.531456, "lng": -13.677889}',
  25000,  -- 25,000 GNF
  5.2,
  'Livraison de test - Commande de nourriture'
);