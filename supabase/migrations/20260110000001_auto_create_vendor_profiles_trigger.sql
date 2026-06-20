-- ================================================================
-- MIGRATION: Trigger automatique de création de profils vendeurs
-- Date: 2026-01-10
-- Objectif: Auto-créer un profil quand un professional_service est créé
-- ================================================================

-- Fonction trigger pour créer automatiquement un profil vendeur
CREATE OR REPLACE FUNCTION public.create_profile_for_professional_service()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  user_email TEXT;
BEGIN
  -- Récupérer l'email de l'utilisateur depuis auth.users
  SELECT email INTO user_email
  FROM auth.users
  WHERE id = NEW.user_id;

  -- Vérifier si le profil existe déjà
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = NEW.user_id) THEN
    -- Créer le profil vendeur
    INSERT INTO profiles (
      id,
      email,
      first_name,
      last_name,
      role,
      is_active,
      status,
      created_at,
      updated_at
    )
    VALUES (
      NEW.user_id,
      COALESCE(user_email, 'email@inconnu.com'),
      COALESCE(SPLIT_PART(NEW.business_name, ' ', 1), NEW.business_name), -- 1er mot = prénom
      COALESCE(NULLIF(SPLIT_PART(NEW.business_name, ' ', 2), ''), ''),   -- 2ème mot = nom
      'vendeur',
      NEW.status = 'active',
      CASE 
        WHEN NEW.status = 'active' THEN 'active'
        WHEN NEW.status = 'pending' THEN 'pending'
        ELSE 'inactive'
      END,
      NEW.created_at,
      NOW()
    );
    
    RAISE NOTICE '✅ Profil vendeur créé automatiquement pour user_id: %', NEW.user_id;
  ELSE
    -- Si le profil existe déjà, s'assurer qu'il a le rôle vendeur
    UPDATE profiles
    SET 
      role = 'vendeur',
      is_active = NEW.status = 'active',
      status = CASE 
        WHEN NEW.status = 'active' THEN 'active'
        WHEN NEW.status = 'pending' THEN 'pending'
        ELSE 'inactive'
      END,
      updated_at = NOW()
    WHERE id = NEW.user_id
      AND role != 'vendeur'; -- Ne pas écraser si déjà vendeur
    
    RAISE NOTICE '✅ Profil existant mis à jour pour user_id: %', NEW.user_id;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS on_professional_service_created ON professional_services;

-- Créer le trigger sur INSERT
CREATE TRIGGER on_professional_service_created
  AFTER INSERT ON professional_services
  FOR EACH ROW
  EXECUTE FUNCTION create_profile_for_professional_service();

-- Commentaire sur la fonction
COMMENT ON FUNCTION create_profile_for_professional_service() IS 
'Trigger qui crée automatiquement un profil vendeur quand un professional_service est créé. 
Créé le 2026-01-10 pour garantir que tous les vendeurs sont visibles dans l interface PDG.';

-- Fonction trigger pour mettre à jour le profil quand le service est modifié
CREATE OR REPLACE FUNCTION public.update_profile_on_service_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Mettre à jour le profil si le status du service change
  IF OLD.status != NEW.status THEN
    UPDATE profiles
    SET 
      is_active = NEW.status = 'active',
      status = CASE 
        WHEN NEW.status = 'active' THEN 'active'
        WHEN NEW.status = 'pending' THEN 'pending'
        ELSE 'inactive'
      END,
      updated_at = NOW()
    WHERE id = NEW.user_id;
    
    RAISE NOTICE '✅ Profil synchronisé avec le status du service: %', NEW.status;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Supprimer l'ancien trigger s'il existe
DROP TRIGGER IF EXISTS on_professional_service_updated ON professional_services;

-- Créer le trigger sur UPDATE
CREATE TRIGGER on_professional_service_updated
  AFTER UPDATE ON professional_services
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION update_profile_on_service_change();

-- Commentaire sur la fonction
COMMENT ON FUNCTION update_profile_on_service_change() IS 
'Trigger qui synchronise le profil vendeur quand le status du service change. 
Créé le 2026-01-10 pour maintenir la cohérence entre professional_services et profiles.';

-- Vérification finale
DO $$
BEGIN
  RAISE NOTICE '✅ Triggers installés:';
  RAISE NOTICE '   - on_professional_service_created (AFTER INSERT)';
  RAISE NOTICE '   - on_professional_service_updated (AFTER UPDATE)';
  RAISE NOTICE '✅ Les futurs vendeurs auront automatiquement un profil';
END $$;
