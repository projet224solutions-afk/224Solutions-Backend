-- ═══════════════════════════════════════════════════════════════════════════════
-- 🟢 SYSTÈME DE PRÉSENCE TEMPS RÉEL ULTRA-RAPIDE
-- Détection instantanée online/offline pour Vista Flows - 224SOLUTIONS
-- Optimisé pour 500K-800K utilisateurs avec Supabase $500/mois
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. TABLE DE PRÉSENCE UTILISATEUR
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS user_presence (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    status VARCHAR(20) NOT NULL DEFAULT 'offline' CHECK (status IN ('online', 'offline', 'away', 'busy', 'in_call')),
    current_device VARCHAR(20) DEFAULT 'web' CHECK (current_device IN ('web', 'mobile', 'desktop')),
    custom_status TEXT,
    last_seen TIMESTAMPTZ DEFAULT NOW(),
    last_active TIMESTAMPTZ DEFAULT NOW(),
    is_typing_in UUID, -- conversation_id où l'utilisateur tape
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour les requêtes fréquentes
CREATE INDEX IF NOT EXISTS idx_user_presence_status ON user_presence(status) WHERE status != 'offline';
CREATE INDEX IF NOT EXISTS idx_user_presence_last_active ON user_presence(last_active DESC);
CREATE INDEX IF NOT EXISTS idx_user_presence_typing ON user_presence(is_typing_in) WHERE is_typing_in IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. TABLE DES INDICATEURS DE FRAPPE
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS typing_indicators (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    expires_at TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '10 seconds'),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(conversation_id, user_id)
);

-- Index pour le nettoyage des indicateurs expirés
CREATE INDEX IF NOT EXISTS idx_typing_expires ON typing_indicators(expires_at);
CREATE INDEX IF NOT EXISTS idx_typing_conversation ON typing_indicators(conversation_id);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. FONCTION DE MISE À JOUR AUTOMATIQUE DU TIMESTAMP
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_presence_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_presence_timestamp ON user_presence;
CREATE TRIGGER trigger_update_presence_timestamp
    BEFORE UPDATE ON user_presence
    FOR EACH ROW
    EXECUTE FUNCTION update_presence_timestamp();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. FONCTION POUR MARQUER AUTOMATIQUEMENT OFFLINE APRÈS INACTIVITÉ
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION auto_mark_offline()
RETURNS void AS $$
BEGIN
    -- Marquer comme away les utilisateurs inactifs depuis 3 minutes (optimisé pour scale)
    UPDATE user_presence
    SET status = 'away', updated_at = NOW()
    WHERE status = 'online'
      AND last_active < NOW() - INTERVAL '3 minutes';

    -- Marquer comme offline les utilisateurs inactifs depuis 10 minutes (optimisé pour scale)
    UPDATE user_presence
    SET status = 'offline', updated_at = NOW()
    WHERE status IN ('online', 'away')
      AND last_active < NOW() - INTERVAL '10 minutes';

    -- Supprimer les indicateurs de frappe expirés
    DELETE FROM typing_indicators
    WHERE expires_at < NOW();
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. FONCTION RPC POUR METTRE À JOUR LA PRÉSENCE (optimisée)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION update_user_presence(
    p_user_id UUID,
    p_status VARCHAR DEFAULT 'online',
    p_device VARCHAR DEFAULT 'web',
    p_custom_status TEXT DEFAULT NULL
)
RETURNS void AS $$
BEGIN
    INSERT INTO user_presence (user_id, status, current_device, custom_status, last_seen, last_active)
    VALUES (p_user_id, p_status, p_device, p_custom_status, NOW(), CASE WHEN p_status != 'offline' THEN NOW() ELSE NULL END)
    ON CONFLICT (user_id) 
    DO UPDATE SET
        status = p_status,
        current_device = p_device,
        custom_status = COALESCE(p_custom_status, user_presence.custom_status),
        last_seen = CASE WHEN p_status = 'offline' THEN NOW() ELSE user_presence.last_seen END,
        last_active = CASE WHEN p_status NOT IN ('offline', 'away') THEN NOW() ELSE user_presence.last_active END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. FONCTION RPC POUR OBTENIR LES UTILISATEURS EN LIGNE
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_online_users(p_user_ids UUID[] DEFAULT NULL)
RETURNS TABLE(
    user_id UUID,
    status VARCHAR,
    current_device VARCHAR,
    custom_status TEXT,
    last_seen TIMESTAMPTZ,
    last_active TIMESTAMPTZ,
    is_online BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        up.user_id,
        up.status,
        up.current_device,
        up.custom_status,
        up.last_seen,
        up.last_active,
        -- Seuil augmenté à 45s pour correspondre au heartbeat de 20s (optimisé pour scale)
        (up.status IN ('online', 'busy', 'in_call') AND up.last_active > NOW() - INTERVAL '45 seconds') AS is_online
    FROM user_presence up
    WHERE (p_user_ids IS NULL OR up.user_id = ANY(p_user_ids))
      AND up.status != 'offline';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. FONCTION RPC POUR HEARTBEAT (ultra-léger)
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION presence_heartbeat(p_user_id UUID)
RETURNS void AS $$
BEGIN
    UPDATE user_presence
    SET last_active = NOW(), updated_at = NOW()
    WHERE user_id = p_user_id AND status IN ('online', 'busy', 'in_call');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. FONCTION POUR INDICATEUR DE FRAPPE
-- ═══════════════════════════════════════════════════════════════════════════════

-- Supprimer l'ancienne fonction si elle existe avec une signature différente
DROP FUNCTION IF EXISTS set_typing_indicator(UUID, UUID, BOOLEAN);

CREATE OR REPLACE FUNCTION set_typing_indicator(
    p_user_id UUID,
    p_conversation_id UUID,
    p_is_typing BOOLEAN DEFAULT TRUE
)
RETURNS void AS $$
BEGIN
    IF p_is_typing THEN
        INSERT INTO typing_indicators (conversation_id, user_id, started_at, expires_at)
        VALUES (p_conversation_id, p_user_id, NOW(), NOW() + INTERVAL '10 seconds')
        ON CONFLICT (conversation_id, user_id)
        DO UPDATE SET started_at = NOW(), expires_at = NOW() + INTERVAL '10 seconds';
        
        -- Mettre à jour la présence aussi
        UPDATE user_presence
        SET is_typing_in = p_conversation_id
        WHERE user_id = p_user_id;
    ELSE
        DELETE FROM typing_indicators
        WHERE conversation_id = p_conversation_id AND user_id = p_user_id;
        
        UPDATE user_presence
        SET is_typing_in = NULL
        WHERE user_id = p_user_id;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 9. POLITIQUES RLS
-- ═══════════════════════════════════════════════════════════════════════════════

ALTER TABLE user_presence ENABLE ROW LEVEL SECURITY;
ALTER TABLE typing_indicators ENABLE ROW LEVEL SECURITY;

-- Tout le monde peut voir la présence des autres
DROP POLICY IF EXISTS "Users can view all presence" ON user_presence;
CREATE POLICY "Users can view all presence" ON user_presence
    FOR SELECT TO authenticated
    USING (true);

-- Chacun peut mettre à jour sa propre présence
DROP POLICY IF EXISTS "Users can update own presence" ON user_presence;
CREATE POLICY "Users can update own presence" ON user_presence
    FOR ALL TO authenticated
    USING (auth.uid() = user_id);

-- Politiques pour typing_indicators
DROP POLICY IF EXISTS "Users can view typing in conversations" ON typing_indicators;
CREATE POLICY "Users can view typing in conversations" ON typing_indicators
    FOR SELECT TO authenticated
    USING (true);

DROP POLICY IF EXISTS "Users can manage own typing" ON typing_indicators;
CREATE POLICY "Users can manage own typing" ON typing_indicators
    FOR ALL TO authenticated
    USING (auth.uid() = user_id);

-- ═══════════════════════════════════════════════════════════════════════════════
-- 10. PUBLICATION REALTIME POUR LES CHANGEMENTS DE PRÉSENCE
-- ═══════════════════════════════════════════════════════════════════════════════

-- S'assurer que la table est dans la publication realtime
DO $$
BEGIN
    -- Ajouter à la publication existante si elle existe
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        BEGIN
            ALTER PUBLICATION supabase_realtime ADD TABLE user_presence;
            ALTER PUBLICATION supabase_realtime ADD TABLE typing_indicators;
        EXCEPTION WHEN duplicate_object THEN
            NULL; -- Table déjà dans la publication
        END;
    END IF;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 11. CRON JOB POUR NETTOYAGE AUTOMATIQUE (via pg_cron si disponible)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Note: Exécuter ceci uniquement si pg_cron est installé
-- SELECT cron.schedule('cleanup-presence', '*/2 * * * *', 'SELECT auto_mark_offline()');

-- ═══════════════════════════════════════════════════════════════════════════════
-- 12. STATISTIQUES DE PRÉSENCE
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW presence_stats AS
SELECT
    status,
    COUNT(*) as count,
    current_device,
    MAX(last_active) as most_recent_activity
FROM user_presence
GROUP BY status, current_device;

GRANT SELECT ON presence_stats TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════
-- COMMENTAIRES
-- ═══════════════════════════════════════════════════════════════════════════════

COMMENT ON TABLE user_presence IS 'Table de présence temps réel des utilisateurs';
COMMENT ON TABLE typing_indicators IS 'Indicateurs temporaires de frappe dans les conversations';
COMMENT ON FUNCTION update_user_presence IS 'Met à jour la présence d''un utilisateur (upsert optimisé)';
COMMENT ON FUNCTION get_online_users IS 'Récupère les utilisateurs actuellement en ligne';
COMMENT ON FUNCTION presence_heartbeat IS 'Heartbeat léger pour confirmer la présence';
COMMENT ON FUNCTION auto_mark_offline IS 'Marque automatiquement offline les utilisateurs inactifs';
