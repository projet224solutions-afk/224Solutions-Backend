-- Synchroniser profiles.public_id avec user_ids.custom_id pour tous les utilisateurs existants
UPDATE profiles p
SET public_id = ui.custom_id
FROM user_ids ui
WHERE p.id = ui.user_id
AND (p.public_id IS NULL OR p.public_id = '');

-- Créer un trigger pour synchroniser automatiquement les nouveaux utilisateurs
CREATE OR REPLACE FUNCTION sync_public_id_from_user_ids()
RETURNS TRIGGER AS $$
BEGIN
  -- Mettre à jour profiles.public_id avec le custom_id de user_ids
  UPDATE profiles
  SET public_id = NEW.custom_id
  WHERE id = NEW.user_id
  AND (public_id IS NULL OR public_id = '');
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- Supprimer le trigger s'il existe déjà
DROP TRIGGER IF EXISTS trigger_sync_public_id ON user_ids;

-- Créer le trigger
CREATE TRIGGER trigger_sync_public_id
AFTER INSERT ON user_ids
FOR EACH ROW
EXECUTE FUNCTION sync_public_id_from_user_ids();

-- Ajouter un index pour améliorer les recherches
CREATE INDEX IF NOT EXISTS idx_profiles_public_id_search ON profiles(public_id) WHERE public_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_ids_custom_id_search ON user_ids(custom_id);