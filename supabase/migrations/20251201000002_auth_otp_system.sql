-- ============================================================================
-- SYSTÈME OTP MULTI-FACTEUR AUTHENTIFICATION - 224SOLUTIONS
-- ============================================================================
-- Date: 1er décembre 2025
-- Description: Table OTP pour MFA agents et bureaux syndicat

-- ============================================================================
-- 1. TABLE OTP
-- ============================================================================

CREATE TABLE IF NOT EXISTS auth_otp_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    
    -- Identification
    identifier VARCHAR(255) NOT NULL, -- email ou phone
    user_type VARCHAR(20) NOT NULL CHECK (user_type IN ('agent', 'bureau', 'vendor', 'driver', 'client')),
    user_id UUID, -- ID de l'agent ou bureau
    
    -- Code OTP
    otp_code VARCHAR(6) NOT NULL,
    otp_hash TEXT NOT NULL, -- Hash bcrypt du code pour sécurité
    
    -- Validité
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ,
    is_valid BOOLEAN DEFAULT true,
    
    -- Tentatives
    verification_attempts INT DEFAULT 0,
    max_attempts INT DEFAULT 5,
    
    -- Métadonnées
    ip_address VARCHAR(50),
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Contrainte: un seul OTP valide à la fois par identifier
    CONSTRAINT unique_active_otp UNIQUE (identifier, user_type, is_valid)
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_otp_identifier ON auth_otp_codes(identifier);
CREATE INDEX IF NOT EXISTS idx_otp_expires_at ON auth_otp_codes(expires_at);
CREATE INDEX IF NOT EXISTS idx_otp_user_type ON auth_otp_codes(user_type);
CREATE INDEX IF NOT EXISTS idx_otp_is_valid ON auth_otp_codes(is_valid);

-- Commentaires
COMMENT ON TABLE auth_otp_codes IS 'Codes OTP pour authentification multi-facteurs';
COMMENT ON COLUMN auth_otp_codes.identifier IS 'Email ou numéro de téléphone';
COMMENT ON COLUMN auth_otp_codes.user_type IS 'Type utilisateur (agent, bureau, vendor, driver, client)';
COMMENT ON COLUMN auth_otp_codes.otp_code IS 'Code OTP 6 chiffres (stocké en clair pour envoi email)';
COMMENT ON COLUMN auth_otp_codes.otp_hash IS 'Hash bcrypt du code pour vérification sécurisée';
COMMENT ON COLUMN auth_otp_codes.expires_at IS 'Date expiration (5 minutes après création)';
COMMENT ON COLUMN auth_otp_codes.verification_attempts IS 'Nombre tentatives de vérification';
COMMENT ON COLUMN auth_otp_codes.max_attempts IS 'Maximum tentatives autorisées (5)';

-- ============================================================================
-- 2. FONCTION: GÉNÉRER OTP
-- ============================================================================

CREATE OR REPLACE FUNCTION generate_otp_code(
    p_identifier VARCHAR,
    p_user_type VARCHAR,
    p_user_id UUID DEFAULT NULL,
    p_ip_address VARCHAR DEFAULT NULL,
    p_user_agent TEXT DEFAULT NULL
)
RETURNS TABLE (
    otp_code VARCHAR,
    expires_at TIMESTAMPTZ
) AS $$
DECLARE
    v_otp VARCHAR(6);
    v_otp_hash TEXT;
    v_expires TIMESTAMPTZ;
BEGIN
    -- Invalider les OTP précédents pour cet identifier
    UPDATE auth_otp_codes
    SET is_valid = false
    WHERE identifier = p_identifier
      AND user_type = p_user_type
      AND is_valid = true;

    -- Générer code OTP 6 chiffres
    v_otp := LPAD(FLOOR(RANDOM() * 1000000)::TEXT, 6, '0');
    
    -- Hasher le code
    v_otp_hash := crypt(v_otp, gen_salt('bf'));
    
    -- Expiration dans 5 minutes
    v_expires := NOW() + INTERVAL '5 minutes';
    
    -- Insérer nouveau OTP
    INSERT INTO auth_otp_codes (
        identifier,
        user_type,
        user_id,
        otp_code,
        otp_hash,
        expires_at,
        ip_address,
        user_agent
    ) VALUES (
        p_identifier,
        p_user_type,
        p_user_id,
        v_otp,
        v_otp_hash,
        v_expires,
        p_ip_address,
        p_user_agent
    );
    
    -- Retourner OTP et expiration
    RETURN QUERY SELECT v_otp, v_expires;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION generate_otp_code IS 'Génère un code OTP 6 chiffres valable 5 minutes';

-- ============================================================================
-- 3. FONCTION: VÉRIFIER OTP
-- ============================================================================

CREATE OR REPLACE FUNCTION verify_otp_code(
    p_identifier VARCHAR,
    p_user_type VARCHAR,
    p_otp_code VARCHAR
)
RETURNS TABLE (
    is_valid BOOLEAN,
    message TEXT,
    user_id UUID,
    attempts_remaining INT
) AS $$
DECLARE
    v_otp_record RECORD;
    v_is_match BOOLEAN;
    v_attempts_remaining INT;
BEGIN
    -- Récupérer l'OTP actif
    SELECT * INTO v_otp_record
    FROM auth_otp_codes
    WHERE identifier = p_identifier
      AND user_type = p_user_type
      AND is_valid = true
      AND used_at IS NULL
    ORDER BY created_at DESC
    LIMIT 1;

    -- Aucun OTP trouvé
    IF v_otp_record IS NULL THEN
        RETURN QUERY SELECT 
            false, 
            'Code OTP invalide ou expiré'::TEXT,
            NULL::UUID,
            0;
        RETURN;
    END IF;

    -- OTP expiré
    IF v_otp_record.expires_at < NOW() THEN
        UPDATE auth_otp_codes
        SET is_valid = false
        WHERE id = v_otp_record.id;
        
        RETURN QUERY SELECT 
            false, 
            'Code OTP expiré'::TEXT,
            NULL::UUID,
            0;
        RETURN;
    END IF;

    -- Trop de tentatives
    IF v_otp_record.verification_attempts >= v_otp_record.max_attempts THEN
        UPDATE auth_otp_codes
        SET is_valid = false
        WHERE id = v_otp_record.id;
        
        RETURN QUERY SELECT 
            false, 
            'Nombre maximum de tentatives atteint'::TEXT,
            NULL::UUID,
            0;
        RETURN;
    END IF;

    -- Incrémenter tentatives
    UPDATE auth_otp_codes
    SET verification_attempts = verification_attempts + 1
    WHERE id = v_otp_record.id;

    -- Vérifier le code (comparaison hash)
    v_is_match := (v_otp_record.otp_hash = crypt(p_otp_code, v_otp_record.otp_hash));

    -- Calculer tentatives restantes
    v_attempts_remaining := v_otp_record.max_attempts - v_otp_record.verification_attempts - 1;

    IF v_is_match THEN
        -- Code correct : marquer comme utilisé
        UPDATE auth_otp_codes
        SET used_at = NOW(),
            is_valid = false
        WHERE id = v_otp_record.id;
        
        RETURN QUERY SELECT 
            true, 
            'Code OTP validé avec succès'::TEXT,
            v_otp_record.user_id,
            v_attempts_remaining;
    ELSE
        -- Code incorrect
        IF v_attempts_remaining <= 0 THEN
            -- Plus de tentatives : invalider OTP
            UPDATE auth_otp_codes
            SET is_valid = false
            WHERE id = v_otp_record.id;
            
            RETURN QUERY SELECT 
                false, 
                'Code incorrect. Nombre maximum de tentatives atteint.'::TEXT,
                NULL::UUID,
                0;
        ELSE
            RETURN QUERY SELECT 
                false, 
                format('Code incorrect. %s tentative(s) restante(s)', v_attempts_remaining)::TEXT,
                NULL::UUID,
                v_attempts_remaining;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION verify_otp_code IS 'Vérifie un code OTP et retourne le résultat';

-- ============================================================================
-- 4. FONCTION: NETTOYER OTP EXPIRÉS
-- ============================================================================

CREATE OR REPLACE FUNCTION cleanup_expired_otp()
RETURNS INT AS $$
DECLARE
    v_deleted_count INT;
BEGIN
    DELETE FROM auth_otp_codes
    WHERE (expires_at < NOW() - INTERVAL '1 hour')
       OR (used_at IS NOT NULL AND used_at < NOW() - INTERVAL '1 day');
    
    GET DIAGNOSTICS v_deleted_count = ROW_COUNT;
    
    RETURN v_deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION cleanup_expired_otp IS 'Supprime les OTP expirés (>1h) ou utilisés (>24h)';

-- ============================================================================
-- 5. CRON JOB: NETTOYAGE AUTOMATIQUE (via pg_cron si disponible)
-- ============================================================================

-- Note: Nécessite extension pg_cron (à activer dans Supabase Dashboard)
-- SELECT cron.schedule(
--     'cleanup-expired-otp',
--     '0 * * * *', -- Chaque heure
--     $$ SELECT cleanup_expired_otp(); $$
-- );

-- ============================================================================
-- 6. RLS POLICIES
-- ============================================================================

ALTER TABLE auth_otp_codes ENABLE ROW LEVEL SECURITY;

-- Seul le système peut lire/écrire les OTP
CREATE POLICY "System only access" ON auth_otp_codes
FOR ALL USING (false);

-- ============================================================================
-- 7. GRANTS
-- ============================================================================

-- Permissions pour service_role (Edge Functions)
GRANT ALL ON auth_otp_codes TO service_role;
GRANT EXECUTE ON FUNCTION generate_otp_code TO service_role;
GRANT EXECUTE ON FUNCTION verify_otp_code TO service_role;
GRANT EXECUTE ON FUNCTION cleanup_expired_otp TO service_role;
