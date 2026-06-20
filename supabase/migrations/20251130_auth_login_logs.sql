-- ============================================================================
-- AUTH LOGIN LOGS TABLE - 224SOLUTIONS
-- Logs des connexions (Agents + Bureaux Syndicat)
-- ============================================================================

CREATE TABLE IF NOT EXISTS auth_login_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_type TEXT NOT NULL CHECK (user_type IN ('agent', 'bureau')),
  user_id UUID NOT NULL,
  identifier TEXT NOT NULL, -- Email ou téléphone utilisé
  success BOOLEAN NOT NULL,
  step TEXT, -- password_validated, otp_verified, etc.
  failure_reason TEXT, -- invalid_password, invalid_otp, account_locked, etc.
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_auth_logs_user ON auth_login_logs(user_type, user_id);
CREATE INDEX IF NOT EXISTS idx_auth_logs_identifier ON auth_login_logs(identifier);
CREATE INDEX IF NOT EXISTS idx_auth_logs_created ON auth_login_logs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_auth_logs_success ON auth_login_logs(success);

-- Commentaires
COMMENT ON TABLE auth_login_logs IS 'Logs des tentatives de connexion (Agents + Bureaux Syndicat)';
COMMENT ON COLUMN auth_login_logs.user_type IS 'Type utilisateur: agent ou bureau';
COMMENT ON COLUMN auth_login_logs.user_id IS 'ID de l''agent (table agents) ou du bureau (table syndicate_bureaus)';
COMMENT ON COLUMN auth_login_logs.identifier IS 'Email ou téléphone utilisé pour la connexion';
COMMENT ON COLUMN auth_login_logs.success IS 'Connexion réussie ou échouée';
COMMENT ON COLUMN auth_login_logs.step IS 'Étape de connexion (password_validated, otp_verified)';
COMMENT ON COLUMN auth_login_logs.failure_reason IS 'Raison de l''échec (invalid_password, invalid_otp, account_locked)';
COMMENT ON COLUMN auth_login_logs.ip_address IS 'Adresse IP du client';
COMMENT ON COLUMN auth_login_logs.user_agent IS 'User-Agent du navigateur';

-- RLS (Row Level Security)
ALTER TABLE auth_login_logs ENABLE ROW LEVEL SECURITY;

-- Policy: Service role peut tout faire
CREATE POLICY "Service role has full access to auth_login_logs"
  ON auth_login_logs
  FOR ALL
  USING (auth.role() = 'service_role');

-- Policy: Agents peuvent voir leurs propres logs
CREATE POLICY "Agents can view their own login logs"
  ON auth_login_logs
  FOR SELECT
  USING (
    user_type = 'agent' 
    AND user_id = auth.uid()
  );

-- Policy: Bureaux peuvent voir leurs propres logs
CREATE POLICY "Bureaux can view their own login logs"
  ON auth_login_logs
  FOR SELECT
  USING (
    user_type = 'bureau' 
    AND user_id = auth.uid()
  );

-- Fonction pour nettoyer les anciens logs (> 90 jours)
CREATE OR REPLACE FUNCTION clean_old_login_logs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM auth_login_logs
  WHERE created_at < NOW() - INTERVAL '90 days';
  
  RAISE NOTICE 'Anciens logs de connexion nettoyés (> 90 jours)';
END;
$$;

COMMENT ON FUNCTION clean_old_login_logs IS 'Nettoie les logs de connexion > 90 jours';

-- Vue pour statistiques de connexion
CREATE OR REPLACE VIEW auth_login_stats AS
SELECT 
  user_type,
  DATE(created_at) as login_date,
  COUNT(*) as total_attempts,
  COUNT(*) FILTER (WHERE success = true) as successful_logins,
  COUNT(*) FILTER (WHERE success = false) as failed_logins,
  COUNT(DISTINCT user_id) as unique_users
FROM auth_login_logs
WHERE created_at >= NOW() - INTERVAL '30 days'
GROUP BY user_type, DATE(created_at)
ORDER BY login_date DESC;

COMMENT ON VIEW auth_login_stats IS 'Statistiques de connexion des 30 derniers jours';
