-- Fix: Les utilisateurs guinéens en Espagne ont des wallets EUR au lieu de GNF
-- Corriger les wallets qui ont été créés avec la mauvaise devise via PayPal
UPDATE wallets 
SET currency = 'GNF', updated_at = now()
WHERE currency = 'EUR' 
AND user_id IN (
  'fca38d2e-c909-41ac-9efb-c2ed4979c622',
  '906e1b70-4584-4925-9fd7-f5cf6a9d7785',
  'bb5f7f19-9c3d-4a3d-8c8b-2f9c8143fa22'
);