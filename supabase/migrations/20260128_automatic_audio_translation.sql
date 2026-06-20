-- ═══════════════════════════════════════════════════════════════════════════════
-- 🎙️ SYSTÈME DE TRADUCTION AUTOMATIQUE DES MESSAGES VOCAUX
-- Déclenche automatiquement la traduction quand un message audio est envoyé
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. COLONNES POUR LA TRADUCTION AUDIO (si pas déjà existantes)
-- ═══════════════════════════════════════════════════════════════════════════════

DO $$ 
BEGIN
    -- Langue originale du message
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'messages' AND column_name = 'original_language') THEN
        ALTER TABLE messages ADD COLUMN original_language VARCHAR(10);
    END IF;

    -- Langue cible pour la traduction
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'messages' AND column_name = 'target_language') THEN
        ALTER TABLE messages ADD COLUMN target_language VARCHAR(10);
    END IF;

    -- Texte transcrit (Speech-to-Text)
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'messages' AND column_name = 'transcribed_text') THEN
        ALTER TABLE messages ADD COLUMN transcribed_text TEXT;
    END IF;

    -- Texte traduit
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'messages' AND column_name = 'translated_text') THEN
        ALTER TABLE messages ADD COLUMN translated_text TEXT;
    END IF;

    -- URL de l'audio traduit
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'messages' AND column_name = 'translated_audio_url') THEN
        ALTER TABLE messages ADD COLUMN translated_audio_url TEXT;
    END IF;

    -- Status de la traduction audio
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'messages' AND column_name = 'audio_translation_status') THEN
        ALTER TABLE messages ADD COLUMN audio_translation_status VARCHAR(20) DEFAULT NULL;
        COMMENT ON COLUMN messages.audio_translation_status IS 'pending, processing, completed, text_only, failed, not_needed';
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. COLONNES DE PRÉFÉRENCE LINGUISTIQUE POUR LES PROFILS
-- ═══════════════════════════════════════════════════════════════════════════════

DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'profiles' AND column_name = 'preferred_language') THEN
        ALTER TABLE profiles ADD COLUMN preferred_language VARCHAR(10) DEFAULT 'fr';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name = 'profiles' AND column_name = 'auto_translate_audio') THEN
        ALTER TABLE profiles ADD COLUMN auto_translate_audio BOOLEAN DEFAULT true;
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. INDEX POUR LES PERFORMANCES
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE INDEX IF NOT EXISTS idx_messages_audio_translation_status 
ON messages(audio_translation_status) 
WHERE type = 'audio' AND audio_translation_status IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_messages_pending_audio_translation
ON messages(created_at DESC)
WHERE type = 'audio' AND audio_translation_status = 'pending';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. FONCTION POUR PRÉPARER UN MESSAGE AUDIO POUR LA TRADUCTION
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION prepare_audio_for_translation()
RETURNS TRIGGER AS $$
DECLARE
    sender_lang VARCHAR(10);
    recipient_lang VARCHAR(10);
    recipient_id UUID;
BEGIN
    -- Seulement pour les messages audio
    IF NEW.type != 'audio' THEN
        RETURN NEW;
    END IF;

    -- Récupérer la langue du sender
    SELECT COALESCE(preferred_language, 'fr') INTO sender_lang
    FROM profiles WHERE id = NEW.sender_id;

    -- Déterminer le destinataire (conversation_id peut être l'ID du destinataire ou une room)
    -- D'abord, essayer de trouver dans une conversation 1-to-1
    IF NEW.conversation_id IS NOT NULL THEN
        -- Si c'est une conversation entre 2 personnes
        SELECT CASE 
            WHEN participant1_id = NEW.sender_id THEN participant2_id
            WHEN participant2_id = NEW.sender_id THEN participant1_id
            ELSE NULL
        END INTO recipient_id
        FROM conversations
        WHERE id = NEW.conversation_id;
        
        -- Si pas trouvé comme ça, utiliser receiver_id si existant
        IF recipient_id IS NULL THEN
            recipient_id := NEW.receiver_id;
        END IF;
    ELSE
        recipient_id := NEW.receiver_id;
    END IF;

    -- Si on a un destinataire, récupérer sa langue
    IF recipient_id IS NOT NULL THEN
        SELECT COALESCE(preferred_language, 'fr') INTO recipient_lang
        FROM profiles WHERE id = recipient_id;
    ELSE
        recipient_lang := 'fr'; -- Défaut
    END IF;

    -- Définir les langues et le statut
    NEW.original_language := sender_lang;
    NEW.target_language := recipient_lang;

    -- Si les langues sont différentes, marquer pour traduction
    IF sender_lang != recipient_lang THEN
        NEW.audio_translation_status := 'pending';
    ELSE
        NEW.audio_translation_status := 'not_needed';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. TRIGGER AUTOMATIQUE SUR INSERT
-- ═══════════════════════════════════════════════════════════════════════════════

DROP TRIGGER IF EXISTS trigger_prepare_audio_translation ON messages;
CREATE TRIGGER trigger_prepare_audio_translation
    BEFORE INSERT ON messages
    FOR EACH ROW
    EXECUTE FUNCTION prepare_audio_for_translation();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. FONCTION POUR APPELER LE WEBHOOK DE TRADUCTION
-- Cette fonction utilise pg_net pour appeler l'Edge Function
-- ═══════════════════════════════════════════════════════════════════════════════

-- Activer l'extension pg_net si disponible
CREATE EXTENSION IF NOT EXISTS pg_net;

CREATE OR REPLACE FUNCTION call_audio_translation_webhook()
RETURNS TRIGGER AS $$
DECLARE
    supabase_url TEXT := 'https://uakkxaibujzxdiqzpnpr.supabase.co';
    service_key TEXT;
BEGIN
    -- Seulement si le statut est 'pending'
    IF NEW.audio_translation_status != 'pending' THEN
        RETURN NEW;
    END IF;

    -- Récupérer la clé de service depuis les secrets (si configurée)
    SELECT decrypted_secret INTO service_key
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_SERVICE_ROLE_KEY'
    LIMIT 1;

    -- Appeler l'Edge Function de traduction via pg_net
    IF service_key IS NOT NULL THEN
        PERFORM net.http_post(
            url := supabase_url || '/functions/v1/audio-translation-webhook',
            headers := jsonb_build_object(
                'Content-Type', 'application/json',
                'Authorization', 'Bearer ' || service_key
            ),
            body := jsonb_build_object(
                'type', TG_OP,
                'record', row_to_json(NEW),
                'table', 'messages',
                'schema', 'public'
            )
        );
    END IF;

    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Ne pas bloquer l'insertion si le webhook échoue
    RAISE WARNING 'Audio translation webhook call failed: %', SQLERRM;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. TRIGGER POUR APPELER LE WEBHOOK APRÈS INSERT
-- ═══════════════════════════════════════════════════════════════════════════════

DROP TRIGGER IF EXISTS trigger_call_audio_translation ON messages;
CREATE TRIGGER trigger_call_audio_translation
    AFTER INSERT ON messages
    FOR EACH ROW
    WHEN (NEW.type = 'audio' AND NEW.audio_translation_status = 'pending')
    EXECUTE FUNCTION call_audio_translation_webhook();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. FONCTION RPC POUR TRAITER LES MESSAGES EN ATTENTE
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION process_pending_audio_translations(max_messages INT DEFAULT 10)
RETURNS TABLE(
    message_id UUID,
    sender_id UUID,
    file_url TEXT,
    original_language VARCHAR,
    target_language VARCHAR
) AS $$
BEGIN
    RETURN QUERY
    UPDATE messages
    SET audio_translation_status = 'processing'
    WHERE id IN (
        SELECT id FROM messages
        WHERE type = 'audio'
          AND audio_translation_status = 'pending'
        ORDER BY created_at ASC
        LIMIT max_messages
        FOR UPDATE SKIP LOCKED
    )
    RETURNING 
        messages.id as message_id,
        messages.sender_id,
        COALESCE(messages.file_url_ios, messages.file_url) as file_url,
        messages.original_language,
        messages.target_language;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 9. FONCTION POUR OBTENIR L'AUDIO TRADUIT POUR UN UTILISATEUR
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_audio_for_user(
    p_message_id UUID,
    p_user_id UUID
)
RETURNS TABLE(
    audio_url TEXT,
    display_text TEXT,
    is_translated BOOLEAN,
    translation_status VARCHAR
) AS $$
DECLARE
    user_lang VARCHAR(10);
    msg_record RECORD;
BEGIN
    -- Récupérer la langue de l'utilisateur
    SELECT COALESCE(preferred_language, 'fr') INTO user_lang
    FROM profiles WHERE id = p_user_id;

    -- Récupérer le message
    SELECT * INTO msg_record FROM messages WHERE id = p_message_id;

    -- Si le message n'existe pas
    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- Si l'utilisateur est l'expéditeur, retourner l'audio original
    IF msg_record.sender_id = p_user_id THEN
        audio_url := COALESCE(msg_record.file_url_ios, msg_record.file_url);
        display_text := msg_record.transcribed_text;
        is_translated := false;
        translation_status := msg_record.audio_translation_status;
        RETURN NEXT;
        RETURN;
    END IF;

    -- Sinon, retourner l'audio traduit si disponible
    IF msg_record.translated_audio_url IS NOT NULL 
       AND msg_record.audio_translation_status = 'completed' THEN
        audio_url := msg_record.translated_audio_url;
        display_text := msg_record.translated_text;
        is_translated := true;
        translation_status := 'completed';
    ELSE
        audio_url := COALESCE(msg_record.file_url_ios, msg_record.file_url);
        display_text := COALESCE(msg_record.transcribed_text, '[En cours de transcription...]');
        is_translated := false;
        translation_status := msg_record.audio_translation_status;
    END IF;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 10. POLITIQUE RLS POUR LES COLONNES DE TRADUCTION
-- ═══════════════════════════════════════════════════════════════════════════════

-- Les politiques existantes sur messages couvrent déjà ces colonnes
-- car elles font partie de la même table

-- ═══════════════════════════════════════════════════════════════════════════════
-- 11. VUE POUR LES STATISTIQUES DE TRADUCTION
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW audio_translation_stats AS
SELECT 
    audio_translation_status as status,
    COUNT(*) as count,
    DATE_TRUNC('day', created_at) as day
FROM messages
WHERE type = 'audio' AND audio_translation_status IS NOT NULL
GROUP BY audio_translation_status, DATE_TRUNC('day', created_at)
ORDER BY day DESC, status;

-- Grant access to the view
GRANT SELECT ON audio_translation_stats TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- COMMENTAIRES
-- ═══════════════════════════════════════════════════════════════════════════════

COMMENT ON FUNCTION prepare_audio_for_translation() IS 
'Prépare automatiquement les messages audio pour la traduction en définissant les langues source/cible';

COMMENT ON FUNCTION call_audio_translation_webhook() IS 
'Appelle l''Edge Function de traduction audio via pg_net après insertion';

COMMENT ON FUNCTION get_audio_for_user(UUID, UUID) IS 
'Retourne l''URL audio appropriée pour un utilisateur (original ou traduit)';
