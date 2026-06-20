-- =====================================================
-- FIX: Statut lecture messages et présence utilisateur
-- =====================================================

-- 1. S'assurer que la colonne status existe dans messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'sent';
ALTER TABLE messages ADD COLUMN IF NOT EXISTS read_at TIMESTAMPTZ;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ;

-- 2. Créer la table user_presence si elle n'existe pas
CREATE TABLE IF NOT EXISTS user_presence (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    status VARCHAR(20) DEFAULT 'offline',
    last_seen TIMESTAMPTZ DEFAULT NOW(),
    last_active TIMESTAMPTZ DEFAULT NOW(),
    current_device VARCHAR(50),
    custom_status VARCHAR(100),
    is_typing_in UUID,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Activer RLS sur user_presence
ALTER TABLE user_presence ENABLE ROW LEVEL SECURITY;

-- 4. Policies pour user_presence
DROP POLICY IF EXISTS "Anyone can view presence" ON user_presence;
CREATE POLICY "Anyone can view presence" ON user_presence
    FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can upsert own presence" ON user_presence;
CREATE POLICY "Users can upsert own presence" ON user_presence
    FOR ALL USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Service role can manage presence" ON user_presence;
CREATE POLICY "Service role can manage presence" ON user_presence
    FOR ALL USING (true);

-- 5. Permettre les INSERT pour les utilisateurs authentifiés
DROP POLICY IF EXISTS "Users can insert own presence" ON user_presence;
CREATE POLICY "Users can insert own presence" ON user_presence
    FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own presence" ON user_presence;  
CREATE POLICY "Users can update own presence" ON user_presence
    FOR UPDATE USING (auth.uid() = user_id);

-- 6. Fonction pour marquer les messages comme lus
CREATE OR REPLACE FUNCTION mark_messages_as_read(
    p_sender_id UUID,
    p_recipient_id UUID
)
RETURNS INTEGER AS $$
DECLARE
    affected_count INTEGER;
BEGIN
    UPDATE messages
    SET read_at = NOW(), status = 'read'
    WHERE sender_id = p_sender_id
    AND recipient_id = p_recipient_id
    AND read_at IS NULL;
    
    GET DIAGNOSTICS affected_count = ROW_COUNT;
    RETURN affected_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Donner les permissions
GRANT EXECUTE ON FUNCTION mark_messages_as_read(UUID, UUID) TO authenticated;

-- 8. Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status);
CREATE INDEX IF NOT EXISTS idx_messages_sender_recipient ON messages(sender_id, recipient_id);

-- 9. Mettre à jour les anciens messages sans statut
UPDATE messages SET status = 'sent' WHERE status IS NULL;

-- 10. Initialiser la présence pour tous les utilisateurs existants
INSERT INTO user_presence (user_id, status, last_seen, updated_at)
SELECT id, 'offline', NOW(), NOW()
FROM auth.users
WHERE id NOT IN (SELECT user_id FROM user_presence)
ON CONFLICT (user_id) DO NOTHING;
