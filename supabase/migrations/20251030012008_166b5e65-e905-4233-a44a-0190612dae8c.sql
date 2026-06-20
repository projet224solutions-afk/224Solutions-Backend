
-- Fonction pour générer un custom_id unique
CREATE OR REPLACE FUNCTION generate_unique_custom_id()
RETURNS TEXT AS $$
DECLARE
  v_custom_id TEXT;
  v_exists BOOLEAN;
BEGIN
  LOOP
    -- Générer un ID au format LLL#### (3 lettres + 4 chiffres)
    v_custom_id := 
      chr(65 + floor(random() * 26)::int) || 
      chr(65 + floor(random() * 26)::int) || 
      chr(65 + floor(random() * 26)::int) || 
      lpad(floor(random() * 10000)::text, 4, '0');
    
    -- Vérifier l'unicité
    SELECT EXISTS(SELECT 1 FROM user_ids WHERE custom_id = v_custom_id) INTO v_exists;
    
    IF NOT v_exists THEN
      RETURN v_custom_id;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour corriger les données manquantes pour tous les utilisateurs
CREATE OR REPLACE FUNCTION fix_missing_user_data()
RETURNS TABLE(
  user_id UUID,
  action TEXT,
  custom_id TEXT,
  wallet_id UUID
) AS $$
DECLARE
  v_user RECORD;
  v_custom_id TEXT;
  v_wallet_id UUID;
  v_user_id_exists BOOLEAN;
  v_wallet_exists BOOLEAN;
BEGIN
  -- Pour chaque profil utilisateur
  FOR v_user IN 
    SELECT p.id, p.email, p.first_name, p.last_name, p.role
    FROM profiles p
  LOOP
    v_custom_id := NULL;
    v_wallet_id := NULL;
    
    -- Vérifier si l'utilisateur a un custom_id
    SELECT EXISTS(SELECT 1 FROM user_ids WHERE user_ids.user_id = v_user.id) INTO v_user_id_exists;
    
    IF NOT v_user_id_exists THEN
      -- Générer et insérer un custom_id
      v_custom_id := generate_unique_custom_id();
      
      INSERT INTO user_ids (user_id, custom_id, created_at)
      VALUES (v_user.id, v_custom_id, NOW());
      
      user_id := v_user.id;
      action := 'custom_id_created';
      custom_id := v_custom_id;
      wallet_id := NULL;
      RETURN NEXT;
    END IF;
    
    -- Vérifier si l'utilisateur a un wallet
    SELECT EXISTS(SELECT 1 FROM wallets WHERE wallets.user_id = v_user.id) INTO v_wallet_exists;
    
    IF NOT v_wallet_exists THEN
      -- Créer un wallet
      INSERT INTO wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
      VALUES (v_user.id, 0, 'GNF', 'active', NOW(), NOW())
      RETURNING id INTO v_wallet_id;
      
      user_id := v_user.id;
      action := 'wallet_created';
      custom_id := NULL;
      wallet_id := v_wallet_id;
      RETURN NEXT;
    END IF;
  END LOOP;
  
  RETURN;
END;
$$ LANGUAGE plpgsql;

-- Exécuter la correction immédiatement
SELECT * FROM fix_missing_user_data();

-- Trigger pour créer automatiquement custom_id et wallet lors de la création d'un profil
CREATE OR REPLACE FUNCTION auto_create_user_data()
RETURNS TRIGGER AS $$
DECLARE
  v_custom_id TEXT;
  v_wallet_id UUID;
BEGIN
  -- Créer custom_id
  v_custom_id := generate_unique_custom_id();
  
  INSERT INTO user_ids (user_id, custom_id, created_at)
  VALUES (NEW.id, v_custom_id, NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- Créer wallet
  INSERT INTO wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
  VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS trigger_auto_create_user_data ON profiles;

-- Créer le trigger
CREATE TRIGGER trigger_auto_create_user_data
  AFTER INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION auto_create_user_data();
