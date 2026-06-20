
-- Stratégie : Désactiver temporairement la contrainte unique, mettre à jour, puis réactiver

-- Étape 1: Supprimer temporairement la contrainte unique sur custom_id
ALTER TABLE user_ids DROP CONSTRAINT IF EXISTS user_ids_custom_id_key;

-- Étape 2: Mettre à jour TOUS les custom_id avec le public_id correct
UPDATE user_ids u
SET custom_id = p.public_id
FROM profiles p
WHERE u.user_id = p.id
  AND p.public_id IS NOT NULL;

-- Étape 3: Insérer les user_ids manquants
INSERT INTO user_ids (user_id, custom_id, created_at)
SELECT p.id, p.public_id, NOW()
FROM profiles p
LEFT JOIN user_ids u ON p.id = u.user_id
WHERE p.public_id IS NOT NULL AND u.user_id IS NULL;

-- Étape 4: Recréer la contrainte unique
ALTER TABLE user_ids ADD CONSTRAINT user_ids_custom_id_key UNIQUE (custom_id);
