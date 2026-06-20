-- ============================================================================
-- AUTH OTP CODES TABLE - 224SOLUTIONS
-- Stockage des codes OTP pour MFA (Agents + Bureaux Syndicat)
-- ============================================================================

CREATE TABLE IF NOT EXISTS auth_otp_codes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_type TEXT NOT NULL CHECK (user_type IN ('agent', 'bureau')),
  user_id UUID NOT NULL,
  identifier TEXT NOT NULL, -- Email ou téléphone utilisé pour la connexion
  otp_code TEXT NOT NULL, -- Code OTP 6 chiffres
  expires_at TIMESTAMPTZ NOT NULL,
  verified BOOLEAN DEFAULT FALSE,
  verified_at TIMESTAMPTZ,
  attempts INT DEFAULT 0, -- Nombre de tentatives de vérification
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_auth_otp_identifier ON auth_otp_codes(identifier);
CREATE INDEX IF NOT EXISTS idx_auth_otp_user ON auth_otp_codes(user_type, user_id);
CREATE INDEX IF NOT EXISTS idx_auth_otp_expires ON auth_otp_codes(expires_at);
CREATE INDEX IF NOT EXISTS idx_auth_otp_verified ON auth_otp_codes(verified);

-- Commentaires
COMMENT ON TABLE auth_otp_codes IS 'Stockage des codes OTP pour authentification MFA (Agents + Bureaux Syndicat)';
COMMENT ON COLUMN auth_otp_codes.user_type IS 'Type utilisateur: agent ou bureau';
COMMENT ON COLUMN auth_otp_codes.user_id IS 'ID de l''agent (table agents) ou du bureau (table syndicate_bureaus)';
COMMENT ON COLUMN auth_otp_codes.identifier IS 'Email ou téléphone utilisé pour la connexion';
COMMENT ON COLUMN auth_otp_codes.otp_code IS 'Code OTP 6 chiffres';
COMMENT ON COLUMN auth_otp_codes.expires_at IS 'Date expiration OTP (5 minutes)';
COMMENT ON COLUMN auth_otp_codes.verified IS 'OTP vérifié avec succès';
COMMENT ON COLUMN auth_otp_codes.attempts IS 'Nombre de tentatives de vérification (max 5)';

-- RLS (Row Level Security)
ALTER TABLE auth_otp_codes ENABLE ROW LEVEL SECURITY;

-- Policy: Service role peut tout faire
CREATE POLICY "Service role has full access to auth_otp_codes"
  ON auth_otp_codes
  FOR ALL
  USING (auth.role() = 'service_role');

-- Fonction pour nettoyer les OTP expirés (à exécuter via cron)
CREATE OR REPLACE FUNCTION clean_expired_otp_codes()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM auth_otp_codes
  WHERE expires_at < NOW() - INTERVAL '1 hour';
  
  RAISE NOTICE 'OTP expirés nettoyés';
END;
$$;

COMMENT ON FUNCTION clean_expired_otp_codes IS 'Nettoie les codes OTP expirés (> 1h)';
