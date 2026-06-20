-- =====================================================
-- SYSTÈME DE COMMUNICATION COMPLET - 224SOLUTIONS
-- =====================================================
-- Date: 2 janvier 2025
-- Version: 1.0.0
-- Description: Système complet de communication avec Agora (Chat + Audio + Vidéo)

-- Extensions nécessaires
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =====================================================
-- 1. CONVERSATIONS
-- =====================================================

-- Types de conversation
CREATE TYPE conversation_type AS ENUM ('private', 'group');
CREATE TYPE conversation_status AS ENUM ('active', 'archived', 'deleted');

-- Table des conversations
CREATE TABLE IF NOT EXISTS conversations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    type conversation_type NOT NULL DEFAULT 'private',
    name VARCHAR(255), -- Nom pour les groupes
    description TEXT, -- Description pour les groupes
    channel_name VARCHAR(64) UNIQUE NOT NULL, -- Canal Agora unique
    
    -- Participants (pour conversations privées)
    participant_1 UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    participant_2 UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Métadonnées
    status conversation_status DEFAULT 'active',
    last_message_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID NOT NULL REFERENCES auth.users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Contraintes
    CONSTRAINT valid_private_conversation CHECK (
        (type = 'private' AND participant_1 IS NOT NULL AND participant_2 IS NOT NULL AND participant_1 != participant_2) OR
        (type = 'group' AND name IS NOT NULL)
    )
);

-- =====================================================
-- 2. PARTICIPANTS DE GROUPE
-- =====================================================

-- Rôles dans les groupes
CREATE TYPE group_role AS ENUM ('admin', 'moderator', 'member');

-- Table des participants de groupe
CREATE TABLE IF NOT EXISTS conversation_participants (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    role group_role DEFAULT 'member',
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    left_at TIMESTAMPTZ,
    is_active BOOLEAN DEFAULT true,
    
    -- Contraintes
    UNIQUE(conversation_id, user_id)
);

-- =====================================================
-- 3. MESSAGES
-- =====================================================

-- Types de message
CREATE TYPE message_type AS ENUM ('text', 'image', 'video', 'audio', 'file', 'location', 'system');
CREATE TYPE message_status AS ENUM ('sent', 'delivered', 'read', 'failed');

-- Table des messages
CREATE TABLE IF NOT EXISTS messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sender_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Contenu du message
    type message_type DEFAULT 'text',
    content TEXT, -- Texte du message
    metadata JSONB DEFAULT '{}', -- Métadonnées (taille fichier, durée audio, etc.)
    
    -- Fichiers attachés
    file_url TEXT, -- URL du fichier (Supabase Storage)
    file_name VARCHAR(255), -- Nom original du fichier
    file_size BIGINT, -- Taille en bytes
    file_type VARCHAR(100), -- Type MIME
    
    -- Localisation (si type = 'location')
    latitude DECIMAL(10, 8),
    longitude DECIMAL(11, 8),
    location_name VARCHAR(255),
    
    -- Statut et métadonnées
    status message_status DEFAULT 'sent',
    reply_to UUID REFERENCES messages(id), -- Message auquel on répond
    edited_at TIMESTAMPTZ,
    deleted_at TIMESTAMPTZ,
    
    -- Timestamps
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 4. STATUT DES MESSAGES (LECTURE)
-- =====================================================

-- Table pour tracker qui a lu quoi
CREATE TABLE IF NOT EXISTS message_read_status (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    read_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Contraintes
    UNIQUE(message_id, user_id)
);

-- =====================================================
-- 5. APPELS (AUDIO/VIDÉO)
-- =====================================================

-- Types et statuts d'appel
CREATE TYPE call_type AS ENUM ('audio', 'video');
CREATE TYPE call_status AS ENUM ('initiated', 'ringing', 'answered', 'ended', 'missed', 'rejected', 'failed');

-- Table des appels
CREATE TABLE IF NOT EXISTS calls (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    channel_name VARCHAR(64) NOT NULL, -- Canal Agora pour l'appel
    
    -- Participants
    caller_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    callee_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    
    -- Détails de l'appel
    type call_type NOT NULL,
    status call_status DEFAULT 'initiated',
    
    -- Timestamps
    initiated_at TIMESTAMPTZ DEFAULT NOW(),
    answered_at TIMESTAMPTZ,
    ended_at TIMESTAMPTZ,
    duration_seconds INTEGER DEFAULT 0, -- Durée en secondes
    
    -- Métadonnées
    end_reason VARCHAR(50), -- 'normal', 'timeout', 'network_error', etc.
    quality_rating INTEGER CHECK (quality_rating >= 1 AND quality_rating <= 5),
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 6. STATUT UTILISATEUR
-- =====================================================

-- Statuts utilisateur
CREATE TYPE user_presence_status AS ENUM ('online', 'offline', 'away', 'busy', 'in_call');

-- Table du statut des utilisateurs
CREATE TABLE IF NOT EXISTS user_presence (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    status user_presence_status DEFAULT 'offline',
    last_seen TIMESTAMPTZ DEFAULT NOW(),
    current_call_id UUID REFERENCES calls(id),
    custom_status VARCHAR(100), -- Statut personnalisé
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 7. NOTIFICATIONS
-- =====================================================

-- Types de notification
CREATE TYPE notification_type AS ENUM ('message', 'call', 'system');
CREATE TYPE notification_status AS ENUM ('pending', 'sent', 'delivered', 'read', 'failed');

-- Table des notifications
CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    type notification_type NOT NULL,
    
    -- Contenu
    title VARCHAR(255) NOT NULL,
    body TEXT NOT NULL,
    data JSONB DEFAULT '{}', -- Données additionnelles
    
    -- Références
    conversation_id UUID REFERENCES conversations(id),
    message_id UUID REFERENCES messages(id),
    call_id UUID REFERENCES calls(id),
    
    -- Statut
    status notification_status DEFAULT 'pending',
    sent_at TIMESTAMPTZ,
    read_at TIMESTAMPTZ,
    
    -- FCM
    fcm_token VARCHAR(255), -- Token FCM du destinataire
    fcm_message_id VARCHAR(255), -- ID du message FCM
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =====================================================
-- 8. TOKENS AGORA (CACHE)
-- =====================================================

-- Table pour cacher les tokens Agora
CREATE TABLE IF NOT EXISTS agora_tokens (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    token_type VARCHAR(10) NOT NULL CHECK (token_type IN ('rtc', 'rtm')),
    token TEXT NOT NULL,
    channel_name VARCHAR(64), -- Pour les tokens RTC
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Index pour la recherche rapide
    UNIQUE(user_id, token_type, channel_name)
);

-- =====================================================
-- 9. INDEX POUR PERFORMANCE
-- =====================================================

-- Index sur les conversations
CREATE INDEX IF NOT EXISTS idx_conversations_participants ON conversations(participant_1, participant_2);
CREATE INDEX IF NOT EXISTS idx_conversations_channel ON conversations(channel_name);
CREATE INDEX IF NOT EXISTS idx_conversations_last_message ON conversations(last_message_at DESC);

-- Index sur les messages
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON messages(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON messages(sender_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_type ON messages(type);
CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status);

-- Index sur les appels
CREATE INDEX IF NOT EXISTS idx_calls_conversation ON calls(conversation_id);
CREATE INDEX IF NOT EXISTS idx_calls_participants ON calls(caller_id, callee_id);
CREATE INDEX IF NOT EXISTS idx_calls_status ON calls(status);
CREATE INDEX IF NOT EXISTS idx_calls_initiated ON calls(initiated_at DESC);

-- Index sur les notifications
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_status ON notifications(status);
CREATE INDEX IF NOT EXISTS idx_notifications_type ON notifications(type);

-- Index sur les tokens
CREATE INDEX IF NOT EXISTS idx_agora_tokens_user ON agora_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_agora_tokens_expires ON agora_tokens(expires_at);

-- =====================================================
-- 10. FONCTIONS UTILITAIRES
-- =====================================================

-- Fonction pour créer une conversation privée
CREATE OR REPLACE FUNCTION create_private_conversation(
    user1_id UUID,
    user2_id UUID
) RETURNS UUID AS $$
DECLARE
    conversation_id UUID;
    channel_name VARCHAR(64);
BEGIN
    -- Générer un nom de canal unique
    channel_name := 'chat_' || LEAST(user1_id::text, user2_id::text) || '_' || GREATEST(user1_id::text, user2_id::text);
    
    -- Vérifier si la conversation existe déjà
    SELECT id INTO conversation_id
    FROM conversations
    WHERE type = 'private'
    AND ((participant_1 = user1_id AND participant_2 = user2_id) OR
         (participant_1 = user2_id AND participant_2 = user1_id));
    
    -- Si elle n'existe pas, la créer
    IF conversation_id IS NULL THEN
        INSERT INTO conversations (type, channel_name, participant_1, participant_2, created_by)
        VALUES ('private', channel_name, user1_id, user2_id, user1_id)
        RETURNING id INTO conversation_id;
    END IF;
    
    RETURN conversation_id;
END;
$$ LANGUAGE plpgsql;

-- Fonction pour marquer un message comme lu
CREATE OR REPLACE FUNCTION mark_message_as_read(
    message_id_param UUID,
    user_id_param UUID
) RETURNS VOID AS $$
BEGIN
    INSERT INTO message_read_status (message_id, user_id)
    VALUES (message_id_param, user_id_param)
    ON CONFLICT (message_id, user_id) DO NOTHING;
    
    -- Mettre à jour le statut du message si tous les participants l'ont lu
    UPDATE messages 
    SET status = 'read'
    WHERE id = message_id_param
    AND status != 'read'
    AND (
        SELECT COUNT(*)
        FROM message_read_status mrs
        WHERE mrs.message_id = message_id_param
    ) >= (
        SELECT CASE 
            WHEN c.type = 'private' THEN 2
            ELSE (SELECT COUNT(*) FROM conversation_participants cp WHERE cp.conversation_id = c.id AND cp.is_active = true)
        END
        FROM conversations c
        JOIN messages m ON m.conversation_id = c.id
        WHERE m.id = message_id_param
    );
END;
$$ LANGUAGE plpgsql;

-- Fonction pour mettre à jour le statut de présence
CREATE OR REPLACE FUNCTION update_user_presence(
    user_id_param UUID,
    status_param user_presence_status,
    custom_status_param VARCHAR(100) DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO user_presence (user_id, status, custom_status, last_seen, updated_at)
    VALUES (user_id_param, status_param, custom_status_param, NOW(), NOW())
    ON CONFLICT (user_id) 
    DO UPDATE SET 
        status = status_param,
        custom_status = COALESCE(custom_status_param, user_presence.custom_status),
        last_seen = NOW(),
        updated_at = NOW();
END;
$$ LANGUAGE plpgsql;

-- =====================================================
-- 11. TRIGGERS
-- =====================================================

-- Trigger pour mettre à jour last_message_at dans conversations
CREATE OR REPLACE FUNCTION update_conversation_last_message()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE conversations 
    SET last_message_at = NEW.created_at, updated_at = NOW()
    WHERE id = NEW.conversation_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_conversation_last_message
    AFTER INSERT ON messages
    FOR EACH ROW
    EXECUTE FUNCTION update_conversation_last_message();

-- Trigger pour nettoyer les tokens expirés
CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM agora_tokens WHERE expires_at < NOW();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_cleanup_expired_tokens
    AFTER INSERT ON agora_tokens
    FOR EACH STATEMENT
    EXECUTE FUNCTION cleanup_expired_tokens();

-- =====================================================
-- 12. RLS (ROW LEVEL SECURITY)
-- =====================================================

-- Activer RLS sur toutes les tables
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversation_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_read_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE calls ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE agora_tokens ENABLE ROW LEVEL SECURITY;

-- Politiques pour conversations
CREATE POLICY "Users can view their conversations" ON conversations
    FOR SELECT USING (
        auth.uid() = participant_1 OR 
        auth.uid() = participant_2 OR
        auth.uid() IN (SELECT user_id FROM conversation_participants WHERE conversation_id = id AND is_active = true)
    );

CREATE POLICY "Users can create conversations" ON conversations
    FOR INSERT WITH CHECK (auth.uid() = created_by);

-- Politiques pour messages
CREATE POLICY "Users can view messages in their conversations" ON messages
    FOR SELECT USING (
        conversation_id IN (
            SELECT id FROM conversations WHERE 
            auth.uid() = participant_1 OR 
            auth.uid() = participant_2 OR
            auth.uid() IN (SELECT user_id FROM conversation_participants WHERE conversation_id = conversations.id AND is_active = true)
        )
    );

CREATE POLICY "Users can send messages" ON messages
    FOR INSERT WITH CHECK (auth.uid() = sender_id);

-- Politiques pour appels
CREATE POLICY "Users can view their calls" ON calls
    FOR SELECT USING (auth.uid() = caller_id OR auth.uid() = callee_id);

CREATE POLICY "Users can create calls" ON calls
    FOR INSERT WITH CHECK (auth.uid() = caller_id);

-- Politiques pour notifications
CREATE POLICY "Users can view their notifications" ON notifications
    FOR SELECT USING (auth.uid() = user_id);

-- Politiques pour tokens Agora
CREATE POLICY "Users can view their tokens" ON agora_tokens
    FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can create their tokens" ON agora_tokens
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- =====================================================
-- 13. DONNÉES DE TEST (OPTIONNEL)
-- =====================================================

-- Insérer des statuts de présence par défaut pour les utilisateurs existants
INSERT INTO user_presence (user_id, status)
SELECT id, 'offline'
FROM auth.users
WHERE id NOT IN (SELECT user_id FROM user_presence)
ON CONFLICT (user_id) DO NOTHING;

-- =====================================================
-- COMMENTAIRES ET DOCUMENTATION
-- =====================================================

COMMENT ON TABLE conversations IS 'Table des conversations (privées et de groupe)';
COMMENT ON TABLE messages IS 'Table des messages avec support multi-média';
COMMENT ON TABLE calls IS 'Table des appels audio/vidéo via Agora';
COMMENT ON TABLE user_presence IS 'Statut de présence des utilisateurs en temps réel';
COMMENT ON TABLE notifications IS 'Notifications push et in-app';
COMMENT ON TABLE agora_tokens IS 'Cache des tokens Agora pour optimiser les performances';

COMMENT ON FUNCTION create_private_conversation IS 'Crée ou récupère une conversation privée entre deux utilisateurs';
COMMENT ON FUNCTION mark_message_as_read IS 'Marque un message comme lu par un utilisateur';
COMMENT ON FUNCTION update_user_presence IS 'Met à jour le statut de présence d\'un utilisateur';
