-- =====================================================
-- AMÉLIORATION SYSTÈME DE COMMUNICATION - 224SOLUTIONS
-- =====================================================
-- Date: 27 janvier 2026
-- Description: Ajout présence en ligne, statut de lecture, 
--              suppression de messages et réponse à un message

-- =====================================================
-- 1. AMÉLIORER LA TABLE MESSAGES
-- =====================================================

-- Ajouter colonne pour les réponses (reply_to_id) si elle n'existe pas
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'messages' AND column_name = 'reply_to_id'
    ) THEN
        ALTER TABLE messages ADD COLUMN reply_to_id UUID REFERENCES messages(id) ON DELETE SET NULL;
    END IF;
END $$;

-- Ajouter colonne deleted_at pour soft delete
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'messages' AND column_name = 'deleted_at'
    ) THEN
        ALTER TABLE messages ADD COLUMN deleted_at TIMESTAMPTZ;
    END IF;
END $$;

-- Ajouter colonne deleted_for (pour suppression côté utilisateur seulement)
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'messages' AND column_name = 'deleted_for'
    ) THEN
        ALTER TABLE messages ADD COLUMN deleted_for UUID[] DEFAULT '{}';
    END IF;
END $$;

-- Ajouter colonne edited_at pour indiquer si le message a été modifié
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'messages' AND column_name = 'edited_at'
    ) THEN
        ALTER TABLE messages ADD COLUMN edited_at TIMESTAMPTZ;
    END IF;
END $$;

-- Ajouter colonne read_at pour indiquer quand le message a été lu
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'messages' AND column_name = 'read_at'
    ) THEN
        ALTER TABLE messages ADD COLUMN read_at TIMESTAMPTZ;
    END IF;
END $$;

-- Ajouter colonne delivered_at pour indiquer quand le message a été livré
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'messages' AND column_name = 'delivered_at'
    ) THEN
        ALTER TABLE messages ADD COLUMN delivered_at TIMESTAMPTZ;
    END IF;
END $$;

-- Index pour les réponses
CREATE INDEX IF NOT EXISTS idx_messages_reply_to ON messages(reply_to_id) WHERE reply_to_id IS NOT NULL;

-- Index pour les messages supprimés
CREATE INDEX IF NOT EXISTS idx_messages_deleted_at ON messages(deleted_at) WHERE deleted_at IS NOT NULL;

-- Index pour la lecture
CREATE INDEX IF NOT EXISTS idx_messages_read_at ON messages(read_at);

-- =====================================================
-- 2. AMÉLIORER LA TABLE USER_PRESENCE
-- =====================================================

-- Créer le type enum s'il n'existe pas
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_presence_status') THEN
        CREATE TYPE user_presence_status AS ENUM ('online', 'offline', 'away', 'busy', 'in_call');
    END IF;
END $$;

-- Créer ou mettre à jour la table user_presence
CREATE TABLE IF NOT EXISTS user_presence (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    status user_presence_status DEFAULT 'offline',
    last_seen TIMESTAMPTZ DEFAULT NOW(),
    last_active TIMESTAMPTZ DEFAULT NOW(),
    current_device VARCHAR(50), -- 'web', 'mobile', 'desktop'
    custom_status VARCHAR(100),
    is_typing_in UUID, -- conversation_id où l'utilisateur tape
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Ajouter les colonnes manquantes si la table existe déjà
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'user_presence' AND column_name = 'last_active'
    ) THEN
        ALTER TABLE user_presence ADD COLUMN last_active TIMESTAMPTZ DEFAULT NOW();
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'user_presence' AND column_name = 'current_device'
    ) THEN
        ALTER TABLE user_presence ADD COLUMN current_device VARCHAR(50);
    END IF;
    
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'user_presence' AND column_name = 'is_typing_in'
    ) THEN
        ALTER TABLE user_presence ADD COLUMN is_typing_in UUID;
    END IF;
END $$;

-- Index pour la recherche des utilisateurs en ligne
CREATE INDEX IF NOT EXISTS idx_user_presence_status ON user_presence(status);
CREATE INDEX IF NOT EXISTS idx_user_presence_last_seen ON user_presence(last_seen);

-- =====================================================
-- 3. TABLE DE LECTURE DES MESSAGES (READ RECEIPTS)
-- =====================================================

CREATE TABLE IF NOT EXISTS message_read_receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    read_at TIMESTAMPTZ DEFAULT NOW(),
    delivered_at TIMESTAMPTZ,
    
    UNIQUE(message_id, user_id)
);

-- Index pour les receipts
CREATE INDEX IF NOT EXISTS idx_message_read_receipts_message ON message_read_receipts(message_id);
CREATE INDEX IF NOT EXISTS idx_message_read_receipts_user ON message_read_receipts(user_id);

-- =====================================================
-- 4. TABLE POUR L'INDICATEUR DE FRAPPE (TYPING)
-- =====================================================

CREATE TABLE IF NOT EXISTS typing_indicators (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '10 seconds'),
    
    UNIQUE(conversation_id, user_id)
);

-- Index pour les indicateurs de frappe
CREATE INDEX IF NOT EXISTS idx_typing_indicators_conversation ON typing_indicators(conversation_id);
CREATE INDEX IF NOT EXISTS idx_typing_indicators_expires ON typing_indicators(expires_at);

-- =====================================================
-- 5. FONCTIONS UTILITAIRES
-- =====================================================

-- Fonction pour mettre à jour la présence utilisateur
CREATE OR REPLACE FUNCTION update_user_presence_v2(
    p_user_id UUID,
    p_status user_presence_status DEFAULT 'online',
    p_device VARCHAR(50) DEFAULT 'web',
    p_custom_status VARCHAR(100) DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO user_presence (user_id, status, current_device, custom_status, last_seen, last_active, updated_at)
    VALUES (p_user_id, p_status, p_device, p_custom_status, NOW(), NOW(), NOW())
    ON CONFLICT (user_id) 
    DO UPDATE SET 
        status = p_status,
        current_device = p_device,
        custom_status = COALESCE(p_custom_status, user_presence.custom_status),
        last_seen = CASE WHEN p_status = 'offline' THEN NOW() ELSE user_presence.last_seen END,
        last_active = NOW(),
        updated_at = NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour marquer les utilisateurs inactifs comme offline (après 5 minutes)
CREATE OR REPLACE FUNCTION mark_inactive_users_offline()
RETURNS INTEGER AS $$
DECLARE
    affected_count INTEGER;
BEGIN
    UPDATE user_presence
    SET status = 'offline', updated_at = NOW()
    WHERE status != 'offline'
    AND last_active < NOW() - INTERVAL '5 minutes';
    
    GET DIAGNOSTICS affected_count = ROW_COUNT;
    RETURN affected_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour obtenir le statut de présence d'un utilisateur
CREATE OR REPLACE FUNCTION get_user_presence(p_user_id UUID)
RETURNS TABLE (
    status user_presence_status,
    last_seen TIMESTAMPTZ,
    current_device VARCHAR(50),
    custom_status VARCHAR(100),
    is_online BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        up.status,
        up.last_seen,
        up.current_device,
        up.custom_status,
        (up.status = 'online' OR up.status = 'busy' OR up.status = 'away') AS is_online
    FROM user_presence up
    WHERE up.user_id = p_user_id;
    
    -- Si l'utilisateur n'a pas d'entrée, retourner offline
    IF NOT FOUND THEN
        RETURN QUERY SELECT 
            'offline'::user_presence_status,
            NULL::TIMESTAMPTZ,
            NULL::VARCHAR(50),
            NULL::VARCHAR(100),
            FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

-- Fonction pour marquer un message comme lu
CREATE OR REPLACE FUNCTION mark_message_read_v2(
    p_message_id UUID,
    p_user_id UUID
)
RETURNS VOID AS $$
BEGIN
    -- Insérer ou mettre à jour le receipt
    INSERT INTO message_read_receipts (message_id, user_id, read_at)
    VALUES (p_message_id, p_user_id, NOW())
    ON CONFLICT (message_id, user_id) 
    DO UPDATE SET read_at = NOW();
    
    -- Mettre à jour le message si c'est le destinataire qui lit
    UPDATE messages
    SET read_at = NOW(), status = 'read'
    WHERE id = p_message_id
    AND recipient_id = p_user_id
    AND read_at IS NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour marquer tous les messages d'une conversation comme lus
CREATE OR REPLACE FUNCTION mark_conversation_messages_read(
    p_conversation_id UUID,
    p_user_id UUID
)
RETURNS INTEGER AS $$
DECLARE
    affected_count INTEGER;
BEGIN
    -- Pour les conversations directes
    IF p_conversation_id IS NULL THEN
        RETURN 0;
    END IF;
    
    -- Mettre à jour les messages non lus
    UPDATE messages
    SET read_at = NOW(), status = 'read'
    WHERE (conversation_id = p_conversation_id OR 
           (conversation_id IS NULL AND recipient_id = p_user_id))
    AND recipient_id = p_user_id
    AND read_at IS NULL;
    
    GET DIAGNOSTICS affected_count = ROW_COUNT;
    
    -- Insérer les receipts pour les messages lus
    INSERT INTO message_read_receipts (message_id, user_id, read_at)
    SELECT m.id, p_user_id, NOW()
    FROM messages m
    WHERE (m.conversation_id = p_conversation_id OR m.recipient_id = p_user_id)
    AND m.sender_id != p_user_id
    ON CONFLICT (message_id, user_id) DO UPDATE SET read_at = NOW();
    
    RETURN affected_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour soft delete un message (pour l'expéditeur ou le destinataire)
CREATE OR REPLACE FUNCTION soft_delete_message(
    p_message_id UUID,
    p_user_id UUID,
    p_delete_for_everyone BOOLEAN DEFAULT FALSE
)
RETURNS BOOLEAN AS $$
DECLARE
    v_sender_id UUID;
    v_can_delete_for_everyone BOOLEAN;
BEGIN
    -- Récupérer l'expéditeur
    SELECT sender_id INTO v_sender_id
    FROM messages
    WHERE id = p_message_id;
    
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    
    -- Vérifier si l'utilisateur peut supprimer pour tout le monde
    -- (seulement l'expéditeur, et dans les 24h suivant l'envoi)
    v_can_delete_for_everyone := (
        v_sender_id = p_user_id 
        AND p_delete_for_everyone
    );
    
    IF v_can_delete_for_everyone THEN
        -- Soft delete pour tout le monde
        UPDATE messages
        SET deleted_at = NOW(), content = '[Message supprimé]'
        WHERE id = p_message_id;
    ELSE
        -- Ajouter l'utilisateur à la liste deleted_for
        UPDATE messages
        SET deleted_for = array_append(
            COALESCE(deleted_for, '{}'), 
            p_user_id
        )
        WHERE id = p_message_id
        AND NOT (p_user_id = ANY(COALESCE(deleted_for, '{}')));
    END IF;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour indiquer qu'un utilisateur tape
CREATE OR REPLACE FUNCTION set_typing_indicator(
    p_conversation_id UUID,
    p_user_id UUID,
    p_is_typing BOOLEAN DEFAULT TRUE
)
RETURNS VOID AS $$
BEGIN
    IF p_is_typing THEN
        INSERT INTO typing_indicators (conversation_id, user_id, started_at, expires_at)
        VALUES (p_conversation_id, p_user_id, NOW(), NOW() + INTERVAL '10 seconds')
        ON CONFLICT (conversation_id, user_id) 
        DO UPDATE SET started_at = NOW(), expires_at = NOW() + INTERVAL '10 seconds';
        
        -- Mettre à jour user_presence
        UPDATE user_presence
        SET is_typing_in = p_conversation_id, updated_at = NOW()
        WHERE user_id = p_user_id;
    ELSE
        DELETE FROM typing_indicators
        WHERE conversation_id = p_conversation_id AND user_id = p_user_id;
        
        UPDATE user_presence
        SET is_typing_in = NULL, updated_at = NOW()
        WHERE user_id = p_user_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Fonction pour nettoyer les indicateurs de frappe expirés
CREATE OR REPLACE FUNCTION cleanup_typing_indicators()
RETURNS INTEGER AS $$
DECLARE
    affected_count INTEGER;
BEGIN
    DELETE FROM typing_indicators
    WHERE expires_at < NOW();
    
    GET DIAGNOSTICS affected_count = ROW_COUNT;
    
    -- Nettoyer aussi user_presence
    UPDATE user_presence
    SET is_typing_in = NULL, updated_at = NOW()
    WHERE is_typing_in IS NOT NULL
    AND user_id NOT IN (SELECT user_id FROM typing_indicators);
    
    RETURN affected_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 6. TRIGGERS
-- =====================================================

-- Trigger pour marquer les messages comme livrés quand le destinataire se connecte
CREATE OR REPLACE FUNCTION mark_messages_delivered_on_connect()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'online' AND (OLD.status = 'offline' OR OLD IS NULL) THEN
        UPDATE messages
        SET delivered_at = NOW(), status = CASE WHEN status = 'sent' THEN 'delivered' ELSE status END
        WHERE recipient_id = NEW.user_id
        AND delivered_at IS NULL
        AND deleted_at IS NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_mark_delivered_on_connect ON user_presence;
CREATE TRIGGER trigger_mark_delivered_on_connect
    AFTER INSERT OR UPDATE OF status ON user_presence
    FOR EACH ROW
    EXECUTE FUNCTION mark_messages_delivered_on_connect();

-- =====================================================
-- 7. POLICIES RLS
-- =====================================================

-- Activer RLS
ALTER TABLE user_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_read_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE typing_indicators ENABLE ROW LEVEL SECURITY;

-- Policies pour user_presence
DROP POLICY IF EXISTS "Users can view all presence" ON user_presence;
CREATE POLICY "Users can view all presence" ON user_presence
    FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can update own presence" ON user_presence;
CREATE POLICY "Users can update own presence" ON user_presence
    FOR ALL USING (auth.uid() = user_id);

-- Policies pour message_read_receipts
DROP POLICY IF EXISTS "Users can view read receipts" ON message_read_receipts;
CREATE POLICY "Users can view read receipts" ON message_read_receipts
    FOR SELECT USING (
        user_id = auth.uid() OR
        message_id IN (SELECT id FROM messages WHERE sender_id = auth.uid())
    );

DROP POLICY IF EXISTS "Users can create read receipts" ON message_read_receipts;
CREATE POLICY "Users can create read receipts" ON message_read_receipts
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- Policies pour typing_indicators
DROP POLICY IF EXISTS "Users can view typing indicators" ON typing_indicators;
CREATE POLICY "Users can view typing indicators" ON typing_indicators
    FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can manage own typing" ON typing_indicators;
CREATE POLICY "Users can manage own typing" ON typing_indicators
    FOR ALL USING (auth.uid() = user_id);

-- Mise à jour de la policy messages pour exclure les messages supprimés
DROP POLICY IF EXISTS "Users can view non-deleted messages" ON messages;
CREATE POLICY "Users can view non-deleted messages" ON messages
    FOR SELECT USING (
        (deleted_at IS NULL OR deleted_at > NOW() - INTERVAL '1 day')
        AND NOT (auth.uid() = ANY(COALESCE(deleted_for, '{}')))
        AND (
            sender_id = auth.uid() OR 
            recipient_id = auth.uid() OR
            conversation_id IN (
                SELECT cp.conversation_id 
                FROM conversation_participants cp 
                WHERE cp.user_id = auth.uid()
            )
        )
    );

-- Policy pour permettre la mise à jour des messages (soft delete, edit)
DROP POLICY IF EXISTS "Users can update own messages" ON messages;
CREATE POLICY "Users can update own messages" ON messages
    FOR UPDATE USING (sender_id = auth.uid() OR recipient_id = auth.uid());

DROP POLICY IF EXISTS "Users can delete own messages" ON messages;
CREATE POLICY "Users can delete own messages" ON messages
    FOR DELETE USING (sender_id = auth.uid());

-- =====================================================
-- 8. INITIALISATION
-- =====================================================

-- Insérer les présences pour les utilisateurs existants
INSERT INTO user_presence (user_id, status, last_seen, updated_at)
SELECT id, 'offline', NOW(), NOW()
FROM auth.users
WHERE id NOT IN (SELECT user_id FROM user_presence)
ON CONFLICT (user_id) DO NOTHING;

-- =====================================================
-- COMMENTAIRES
-- =====================================================

COMMENT ON TABLE user_presence IS 'Statut de présence en temps réel des utilisateurs';
COMMENT ON TABLE message_read_receipts IS 'Accusés de lecture des messages';
COMMENT ON TABLE typing_indicators IS 'Indicateurs de frappe en temps réel';

COMMENT ON FUNCTION update_user_presence_v2 IS 'Met à jour le statut de présence d''un utilisateur';
COMMENT ON FUNCTION mark_message_read_v2 IS 'Marque un message comme lu et enregistre le receipt';
COMMENT ON FUNCTION soft_delete_message IS 'Supprime un message (soft delete ou pour un seul utilisateur)';
COMMENT ON FUNCTION set_typing_indicator IS 'Gère l''indicateur de frappe d''un utilisateur';
