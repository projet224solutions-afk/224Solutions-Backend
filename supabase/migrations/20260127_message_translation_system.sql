-- Migration: Message Translation System
-- Description: Ajoute le support de traduction automatique pour la messagerie multi-langue

-- Ajouter les colonnes de traduction à la table messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS translated_content TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS original_language VARCHAR(10);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS target_language VARCHAR(10);
ALTER TABLE messages ADD COLUMN IF NOT EXISTS translation_status VARCHAR(20) DEFAULT 'none';

-- Ajouter la langue préférée aux profils utilisateurs
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS preferred_language VARCHAR(10) DEFAULT 'fr';

-- Créer un index pour optimiser les requêtes de traduction
CREATE INDEX IF NOT EXISTS idx_messages_translation_status ON messages(translation_status) 
  WHERE translation_status IS NOT NULL AND translation_status != 'none';

CREATE INDEX IF NOT EXISTS idx_messages_target_language ON messages(target_language) 
  WHERE target_language IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_preferred_language ON profiles(preferred_language);

-- Commentaires
COMMENT ON COLUMN messages.translated_content IS 'Contenu du message traduit dans la langue du destinataire';
COMMENT ON COLUMN messages.original_language IS 'Langue détectée du message original (ISO 639-1: fr, en, ar, es, pt, etc.)';
COMMENT ON COLUMN messages.target_language IS 'Langue cible de la traduction';
COMMENT ON COLUMN messages.translation_status IS 'Statut de traduction: none, pending, completed, failed';
COMMENT ON COLUMN profiles.preferred_language IS 'Langue préférée de l''utilisateur pour l''interface et les traductions';

-- Fonction pour obtenir la langue préférée d'un utilisateur
CREATE OR REPLACE FUNCTION get_user_preferred_language(user_uuid UUID)
RETURNS VARCHAR(10)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  lang VARCHAR(10);
BEGIN
  SELECT preferred_language INTO lang
  FROM profiles
  WHERE id = user_uuid;
  
  -- Défaut: français si non défini
  RETURN COALESCE(lang, 'fr');
END;
$$;

-- Fonction pour vérifier si une traduction est nécessaire
CREATE OR REPLACE FUNCTION needs_translation(
  sender_lang VARCHAR(10),
  recipient_uuid UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  recipient_lang VARCHAR(10);
BEGIN
  recipient_lang := get_user_preferred_language(recipient_uuid);
  
  -- Traduction nécessaire si les langues sont différentes
  RETURN sender_lang IS DISTINCT FROM recipient_lang;
END;
$$;

-- Trigger pour marquer les messages qui nécessitent une traduction
CREATE OR REPLACE FUNCTION check_translation_needed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  sender_lang VARCHAR(10);
  recipient_lang VARCHAR(10);
BEGIN
  -- Obtenir la langue du sender
  SELECT preferred_language INTO sender_lang
  FROM profiles
  WHERE id = NEW.sender_id;
  
  -- Obtenir la langue du recipient
  SELECT preferred_language INTO recipient_lang
  FROM profiles
  WHERE id = NEW.recipient_id;
  
  -- Stocker la langue originale
  NEW.original_language := COALESCE(sender_lang, 'fr');
  
  -- Si les langues sont différentes, marquer pour traduction
  IF sender_lang IS DISTINCT FROM recipient_lang AND recipient_lang IS NOT NULL THEN
    NEW.target_language := recipient_lang;
    NEW.translation_status := 'pending';
  ELSE
    NEW.translation_status := 'none';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_check_translation_needed ON messages;
CREATE TRIGGER trigger_check_translation_needed
  BEFORE INSERT ON messages
  FOR EACH ROW
  EXECUTE FUNCTION check_translation_needed();

-- Vue pour obtenir les messages avec traduction pour un utilisateur
CREATE OR REPLACE VIEW messages_with_translation AS
SELECT 
  m.*,
  -- Afficher le contenu traduit si disponible et si c'est la langue cible de l'utilisateur
  CASE 
    WHEN m.translation_status = 'completed' AND m.translated_content IS NOT NULL 
    THEN m.translated_content
    ELSE m.content
  END AS display_content,
  -- Indiquer si le message affiché est une traduction
  (m.translation_status = 'completed' AND m.translated_content IS NOT NULL) AS is_translated
FROM messages m;

-- Fonction RPC pour obtenir les messages traduits pour un utilisateur
CREATE OR REPLACE FUNCTION get_translated_messages(
  p_conversation_id UUID,
  p_user_id UUID,
  p_limit INT DEFAULT 50
)
RETURNS TABLE (
  id UUID,
  conversation_id UUID,
  sender_id UUID,
  recipient_id UUID,
  content TEXT,
  display_content TEXT,
  is_translated BOOLEAN,
  original_language VARCHAR(10),
  type VARCHAR(20),
  status VARCHAR(20),
  created_at TIMESTAMPTZ,
  file_url TEXT,
  file_name TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  user_lang VARCHAR(10);
BEGIN
  -- Obtenir la langue de l'utilisateur
  user_lang := get_user_preferred_language(p_user_id);
  
  RETURN QUERY
  SELECT 
    m.id,
    m.conversation_id,
    m.sender_id,
    m.recipient_id,
    m.content,
    -- Afficher la traduction si disponible et si la langue cible correspond
    CASE 
      WHEN m.translation_status = 'completed' 
           AND m.translated_content IS NOT NULL 
           AND m.target_language = user_lang
      THEN m.translated_content
      ELSE m.content
    END AS display_content,
    -- Indiquer si c'est une traduction
    (m.translation_status = 'completed' 
     AND m.translated_content IS NOT NULL 
     AND m.target_language = user_lang) AS is_translated,
    m.original_language,
    m.type,
    m.status,
    m.created_at,
    m.file_url,
    m.file_name
  FROM messages m
  WHERE m.conversation_id = p_conversation_id
  ORDER BY m.created_at DESC
  LIMIT p_limit;
END;
$$;

-- Index pour améliorer les performances de la fonction RPC
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created 
  ON messages(conversation_id, created_at DESC);

-- Note: L'application doit:
-- 1. Définir la langue préférée de l'utilisateur lors de l'inscription/profil
-- 2. Appeler la fonction Edge 'translate-message' pour les messages en status 'pending'
-- 3. Utiliser 'display_content' au lieu de 'content' pour l'affichage
-- 4. Permettre à l'utilisateur de voir l'original via un bouton "Voir l'original"
