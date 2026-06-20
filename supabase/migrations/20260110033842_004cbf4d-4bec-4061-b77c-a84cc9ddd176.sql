
-- Correction du compte EBD8646 vers le format standardisé VND0008
-- Utilisateur: Thierno Souleymane Bah (vendeur)

-- Mettre à jour user_ids
UPDATE user_ids 
SET custom_id = 'VND0008' 
WHERE user_id = 'b11e7223-c98f-4f06-a99e-70bf098bf411';

-- Mettre à jour profiles
UPDATE profiles 
SET public_id = 'VND0008' 
WHERE id = 'b11e7223-c98f-4f06-a99e-70bf098bf411';
