-- Migration: Audio Format Compatibility
-- Description: Améliore la compatibilité des messages vocaux entre différents appareils

-- Ajouter une colonne pour stocker le format audio original
ALTER TABLE messages ADD COLUMN IF NOT EXISTS audio_format TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS audio_mime_type TEXT;

-- Ajouter une colonne pour l'URL du fichier converti (compatible iOS)
ALTER TABLE messages ADD COLUMN IF NOT EXISTS file_url_ios TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS audio_format_ios TEXT;

-- Créer un index pour optimiser les requêtes sur les fichiers audio
CREATE INDEX IF NOT EXISTS idx_messages_audio_format ON messages(audio_format) WHERE audio_format IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_messages_file_url_ios ON messages(file_url_ios) WHERE file_url_ios IS NOT NULL;

-- Commentaires
COMMENT ON COLUMN messages.audio_format IS 'Format du fichier audio (mp4, webm, mp3, ogg, wav, m4a)';
COMMENT ON COLUMN messages.audio_mime_type IS 'Type MIME complet du fichier audio (audio/webm, audio/mp4, etc.)';
COMMENT ON COLUMN messages.file_url_ios IS 'URL du fichier audio converti pour iOS (format m4a/mp4)';
COMMENT ON COLUMN messages.audio_format_ios IS 'Format du fichier audio converti pour iOS';

-- Fonction pour détecter le format audio à partir du nom de fichier
CREATE OR REPLACE FUNCTION get_audio_format(file_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
  IF file_name IS NULL THEN
    RETURN NULL;
  END IF;
  
  -- Extraire l'extension
  IF file_name ILIKE '%.mp4' THEN RETURN 'mp4';
  ELSIF file_name ILIKE '%.m4a' THEN RETURN 'm4a';
  ELSIF file_name ILIKE '%.webm' THEN RETURN 'webm';
  ELSIF file_name ILIKE '%.mp3' THEN RETURN 'mp3';
  ELSIF file_name ILIKE '%.ogg' THEN RETURN 'ogg';
  ELSIF file_name ILIKE '%.wav' THEN RETURN 'wav';
  ELSIF file_name ILIKE '%.aac' THEN RETURN 'aac';
  ELSE RETURN NULL;
  END IF;
END;
$$;

-- Mettre à jour les messages existants avec le format audio
UPDATE messages 
SET audio_format = get_audio_format(file_name)
WHERE type = 'audio' 
  AND audio_format IS NULL 
  AND file_name IS NOT NULL;

-- Trigger pour définir automatiquement le format audio lors de l'insertion
CREATE OR REPLACE FUNCTION set_audio_format()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.type = 'audio' AND NEW.audio_format IS NULL AND NEW.file_name IS NOT NULL THEN
    NEW.audio_format := get_audio_format(NEW.file_name);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_set_audio_format ON messages;
CREATE TRIGGER trigger_set_audio_format
  BEFORE INSERT OR UPDATE ON messages
  FOR EACH ROW
  EXECUTE FUNCTION set_audio_format();

-- Note: Pour une compatibilité maximale, l'application doit:
-- 1. iOS: Enregistrer en MP4/M4A (audio/mp4)
-- 2. Android/Desktop: Enregistrer en WebM (audio/webm) ou MP4 (audio/mp4)
-- 3. Afficher un bouton de téléchargement si le format n'est pas supporté
