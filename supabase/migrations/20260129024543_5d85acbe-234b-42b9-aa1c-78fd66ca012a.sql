-- Corriger le trigger qui utilise receiver_id au lieu de recipient_id
CREATE OR REPLACE FUNCTION prepare_audio_for_translation()
RETURNS TRIGGER AS $$
DECLARE
    sender_lang VARCHAR(10);
    recipient_lang VARCHAR(10);
    target_recipient_id UUID;
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
        END INTO target_recipient_id
        FROM conversations
        WHERE id = NEW.conversation_id;
        
        -- Si pas trouvé comme ça, utiliser recipient_id (CORRIGÉ: était receiver_id)
        IF target_recipient_id IS NULL THEN
            target_recipient_id := NEW.recipient_id;
        END IF;
    ELSE
        target_recipient_id := NEW.recipient_id;
    END IF;

    -- Si on a un destinataire, récupérer sa langue
    IF target_recipient_id IS NOT NULL THEN
        SELECT COALESCE(preferred_language, 'fr') INTO recipient_lang
        FROM profiles WHERE id = target_recipient_id;
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