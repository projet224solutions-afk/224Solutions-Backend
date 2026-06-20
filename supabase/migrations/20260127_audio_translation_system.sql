-- Migration: Audio Translation System
-- Description: Ajoute le support de traduction audio automatique pour la communication multilingue

-- Ajouter les colonnes de traduction audio à la table messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS transcribed_text TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS translated_text TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS translated_audio_url TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS audio_translation_status VARCHAR(20) DEFAULT 'none';

-- Commentaires
COMMENT ON COLUMN messages.transcribed_text IS 'Texte transcrit du message audio original (speech-to-text)';
COMMENT ON COLUMN messages.translated_text IS 'Texte traduit dans la langue du destinataire';
COMMENT ON COLUMN messages.translated_audio_url IS 'URL du fichier audio traduit et synthétisé (text-to-speech)';
COMMENT ON COLUMN messages.audio_translation_status IS 'Statut: none, pending, text_only, completed, failed';

-- Index pour optimiser les requêtes
CREATE INDEX IF NOT EXISTS idx_messages_audio_translation_status 
  ON messages(audio_translation_status) 
  WHERE audio_translation_status IS NOT NULL AND audio_translation_status != 'none';

CREATE INDEX IF NOT EXISTS idx_messages_translated_audio 
  ON messages(translated_audio_url) 
  WHERE translated_audio_url IS NOT NULL;

-- Trigger pour marquer les messages audio qui nécessitent une traduction
CREATE OR REPLACE FUNCTION check_audio_translation_needed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  sender_lang VARCHAR(10);
  recipient_lang VARCHAR(10);
BEGIN
  -- Seulement pour les messages audio
  IF NEW.type != 'audio' THEN
    RETURN NEW;
  END IF;

  -- Obtenir la langue du sender
  SELECT preferred_language INTO sender_lang
  FROM profiles
  WHERE id = NEW.sender_id;
  
  -- Obtenir la langue du recipient
  SELECT preferred_language INTO recipient_lang
  FROM profiles
  WHERE id = NEW.recipient_id;
  
  -- Si les langues sont différentes, marquer pour traduction audio
  IF sender_lang IS DISTINCT FROM recipient_lang AND recipient_lang IS NOT NULL THEN
    NEW.original_language := COALESCE(sender_lang, 'fr');
    NEW.target_language := recipient_lang;
    NEW.audio_translation_status := 'pending';
  ELSE
    NEW.audio_translation_status := 'none';
  END IF;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_check_audio_translation_needed ON messages;
CREATE TRIGGER trigger_check_audio_translation_needed
  BEFORE INSERT ON messages
  FOR EACH ROW
  WHEN (NEW.type = 'audio')
  EXECUTE FUNCTION check_audio_translation_needed();

-- Fonction RPC pour obtenir l'audio approprié pour un utilisateur
CREATE OR REPLACE FUNCTION get_audio_for_user(
  p_message_id UUID,
  p_user_id UUID
)
RETURNS TABLE (
  audio_url TEXT,
  is_translated BOOLEAN,
  transcribed_text TEXT,
  original_language VARCHAR(10)
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  user_lang VARCHAR(10);
  msg_record RECORD;
BEGIN
  -- Obtenir la langue de l'utilisateur
  SELECT preferred_language INTO user_lang
  FROM profiles
  WHERE id = p_user_id;
  
  -- Obtenir le message
  SELECT * INTO msg_record
  FROM messages
  WHERE id = p_message_id;
  
  IF msg_record IS NULL THEN
    RETURN;
  END IF;
  
  -- Si l'audio traduit est disponible et correspond à la langue de l'utilisateur
  IF msg_record.audio_translation_status = 'completed' 
     AND msg_record.translated_audio_url IS NOT NULL 
     AND msg_record.target_language = user_lang THEN
    RETURN QUERY SELECT 
      msg_record.translated_audio_url,
      TRUE,
      msg_record.translated_text,
      msg_record.original_language;
  ELSE
    -- Retourner l'audio original
    RETURN QUERY SELECT 
      COALESCE(msg_record.file_url_ios, msg_record.file_url),
      FALSE,
      msg_record.transcribed_text,
      msg_record.original_language;
  END IF;
END;
$$;

-- Vue pour les messages audio avec traduction
CREATE OR REPLACE VIEW audio_messages_with_translation AS
SELECT 
  m.id,
  m.conversation_id,
  m.sender_id,
  m.recipient_id,
  m.file_url AS original_audio_url,
  m.file_url_ios AS original_audio_url_ios,
  m.translated_audio_url,
  m.transcribed_text,
  m.translated_text,
  m.original_language,
  m.target_language,
  m.audio_translation_status,
  m.created_at,
  -- Déterminer quel audio afficher selon la langue du destinataire
  CASE 
    WHEN m.audio_translation_status = 'completed' AND m.translated_audio_url IS NOT NULL 
    THEN m.translated_audio_url
    ELSE COALESCE(m.file_url_ios, m.file_url)
  END AS display_audio_url
FROM messages m
WHERE m.type = 'audio';

-- Fonction pour obtenir les messages audio en attente de traduction
CREATE OR REPLACE FUNCTION get_pending_audio_translations(p_limit INT DEFAULT 10)
RETURNS TABLE (
  message_id UUID,
  audio_url TEXT,
  original_language VARCHAR(10),
  target_language VARCHAR(10),
  sender_id UUID,
  recipient_id UUID
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    m.id AS message_id,
    COALESCE(m.file_url_ios, m.file_url) AS audio_url,
    m.original_language,
    m.target_language,
    m.sender_id,
    m.recipient_id
  FROM messages m
  WHERE m.type = 'audio'
    AND m.audio_translation_status = 'pending'
    AND m.file_url IS NOT NULL
  ORDER BY m.created_at ASC
  LIMIT p_limit;
END;
$$;

-- Note: L'application doit:
-- 1. Configurer GOOGLE_CLOUD_API_KEY dans les secrets Supabase pour STT/TTS
-- 2. Appeler translate-audio pour les messages en status 'pending'
-- 3. Utiliser get_audio_for_user() pour obtenir le bon audio selon l'utilisateur
-- 4. Afficher l'audio traduit au destinataire, l'original à l'émetteur
