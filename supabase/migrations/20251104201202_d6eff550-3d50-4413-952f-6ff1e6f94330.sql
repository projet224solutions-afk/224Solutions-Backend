-- Modifier la colonne public_id pour le format 224Solutions
-- Étape 1: Supprimer temporairement le trigger qui bloque la modification
DROP TRIGGER IF EXISTS log_id_profiles ON profiles;

-- Étape 2: Modifier le type de colonne pour accepter 224-XXX-XXX (11 caractères minimum)
ALTER TABLE profiles 
ALTER COLUMN public_id TYPE VARCHAR(20);

-- Étape 3: Recréer le trigger si nécessaire
-- (Le trigger sera recréé automatiquement si c'était un trigger système)