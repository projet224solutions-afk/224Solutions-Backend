-- Correction des coordonnées GPS avec les VRAIES positions selon Google Geocoding API

-- 224Solution - Coyah, Claudia (vraies coordonnées de Coyah)
UPDATE vendors 
SET latitude = 9.7086357, longitude = -13.3876116
WHERE id = '42a36345-bfcb-4ecd-85e4-a624803b6a4f';

-- Ismael Bah - Ratoma, Conakry (vraies coordonnées de Ratoma selon Google)
UPDATE vendors 
SET latitude = 9.583333, longitude = -13.65
WHERE id = '35852b1a-ee6f-4618-a674-8f4b895685fd';

-- Thierno Bah - Dixinn, Conakry (vraies coordonnées de Dixinn selon Google)
UPDATE vendors 
SET latitude = 9.550278, longitude = -13.672011
WHERE id = '0ae9d3b0-5ef7-4bfb-83a7-5b819c15ca78';

-- Utilisateur - Matoto, Conakry (vraies coordonnées de Matoto selon Google)
UPDATE vendors 
SET latitude = 9.5806557, longitude = -13.6153137
WHERE id = '9e622843-f7c1-4a05-95f2-69429ceac420';