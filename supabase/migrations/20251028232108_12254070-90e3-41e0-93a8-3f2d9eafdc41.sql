-- Migration: Système de transfert wallet amélioré
-- Créer des custom_id pour tous les utilisateurs existants qui n'en ont pas

-- 1. Fonction pour générer un custom_id unique
CREATE OR REPLACE FUNCTION generate_user_custom_id()
RETURNS TEXT AS $$
DECLARE
  new_id TEXT;
  exists_check INT;
BEGIN
  LOOP
    -- Générer un code aléatoire (3 lettres + 4 chiffres)
    new_id := UPPER(
      CHR(65 + floor(random() * 26)::int) ||
      CHR(65 + floor(random() * 26)::int) ||
      CHR(65 + floor(random() * 26)::int) ||
      LPAD(floor(random() * 10000)::text, 4, '0')
    );
    
    -- Vérifier si l'ID existe déjà
    SELECT COUNT(*) INTO exists_check
    FROM user_ids
    WHERE custom_id = new_id;
    
    EXIT WHEN exists_check = 0;
  END LOOP;
  
  RETURN new_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Trigger pour créer automatiquement un custom_id lors de l'inscription
CREATE OR REPLACE FUNCTION create_user_custom_id_on_signup()
RETURNS TRIGGER AS $$
BEGIN
  -- Insérer dans user_ids avec un custom_id généré
  INSERT INTO user_ids (user_id, custom_id)
  VALUES (NEW.id, generate_user_custom_id())
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS on_auth_user_created_custom_id ON auth.users;

-- Créer le nouveau trigger
CREATE TRIGGER on_auth_user_created_custom_id
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION create_user_custom_id_on_signup();

-- 3. Créer des custom_id pour tous les utilisateurs qui n'en ont pas
INSERT INTO user_ids (user_id, custom_id)
SELECT 
  au.id,
  generate_user_custom_id()
FROM auth.users au
WHERE NOT EXISTS (
  SELECT 1 FROM user_ids ui WHERE ui.user_id = au.id
)
ON CONFLICT (user_id) DO NOTHING;

-- 4. Politique RLS pour user_ids (lecture publique pour recherche)
ALTER TABLE user_ids ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can read user_ids" ON user_ids;
CREATE POLICY "Anyone can read user_ids"
  ON user_ids FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Users can read their own user_id" ON user_ids;
CREATE POLICY "Users can read their own user_id"
  ON user_ids FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id);

-- 5. Vue pour faciliter la recherche d'utilisateurs par custom_id
CREATE OR REPLACE VIEW user_search_view AS
SELECT 
  ui.custom_id,
  ui.user_id,
  p.email,
  p.first_name,
  p.last_name,
  p.phone
FROM user_ids ui
LEFT JOIN profiles p ON p.id = ui.user_id;

-- Politique RLS pour la vue
ALTER VIEW user_search_view SET (security_invoker = true);

GRANT SELECT ON user_search_view TO authenticated;