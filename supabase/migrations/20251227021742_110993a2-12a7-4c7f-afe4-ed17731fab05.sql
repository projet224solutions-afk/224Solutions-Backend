-- Correction des coordonnées GPS avec les vraies positions géographiques
-- Ratoma, Conakry est à environ 40km de Coyah

-- Ismael Bah - Ratoma, Conakry (vraies coordonnées de Ratoma)
UPDATE vendors 
SET latitude = 9.5500, longitude = -13.6800
WHERE id = '35852b1a-ee6f-4618-a674-8f4b895685fd';

-- Thierno Bah - Dixinn, Conakry (vraies coordonnées de Dixinn)
UPDATE vendors 
SET latitude = 9.5350, longitude = -13.6950
WHERE id = '0ae9d3b0-5ef7-4bfb-83a7-5b819c15ca78';

-- Utilisateur - Matoto, Conakry (vraies coordonnées de Matoto)
UPDATE vendors 
SET latitude = 9.5800, longitude = -13.6200
WHERE id = '9e622843-f7c1-4a05-95f2-69429ceac420';

-- Fusion Digitale LTD - Kaloum, Conakry (centre-ville, coordonnées correctes)
UPDATE vendors 
SET latitude = 9.5092, longitude = -13.7122
WHERE id = 'e04b0799-ccd3-4fbe-9962-c327a743f6f9';

-- Fusion Digitale LTD2 - Matam, Conakry 
UPDATE vendors 
SET latitude = 9.5200, longitude = -13.7000
WHERE id = '5c9381ee-937e-4aa3-a712-32eb94e2dc7f';