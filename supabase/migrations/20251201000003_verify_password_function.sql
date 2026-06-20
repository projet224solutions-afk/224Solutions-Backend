-- ============================================================================
-- FONCTION UTILITAIRE: VÉRIFICATION MOT DE PASSE - 224SOLUTIONS
-- ============================================================================

-- Fonction pour vérifier un mot de passe hashé avec bcrypt
CREATE OR REPLACE FUNCTION verify_password(
    p_password TEXT,
    p_hash TEXT
)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (p_hash = crypt(p_password, p_hash));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION verify_password IS 'Vérifie un mot de passe contre son hash bcrypt';

-- Grant aux Edge Functions
GRANT EXECUTE ON FUNCTION verify_password TO service_role;
