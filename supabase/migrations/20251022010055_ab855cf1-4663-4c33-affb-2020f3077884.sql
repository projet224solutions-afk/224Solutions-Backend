-- Table pour tracker les installations PWA
CREATE TABLE IF NOT EXISTS pwa_installations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID NOT NULL REFERENCES bureaus(id) ON DELETE CASCADE,
  token TEXT,
  installed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  platform TEXT,
  is_mobile BOOLEAN DEFAULT false,
  user_agent TEXT,
  ip_address TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_pwa_installations_bureau ON pwa_installations(bureau_id);
CREATE INDEX IF NOT EXISTS idx_pwa_installations_token ON pwa_installations(token);

-- Table pour stocker les tokens JWT générés
CREATE TABLE IF NOT EXISTS pwa_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID NOT NULL REFERENCES bureaus(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_by UUID,
  used BOOLEAN DEFAULT false,
  used_at TIMESTAMP WITH TIME ZONE
);

-- Index pour tokens
CREATE INDEX IF NOT EXISTS idx_pwa_tokens_bureau ON pwa_tokens(bureau_id);
CREATE INDEX IF NOT EXISTS idx_pwa_tokens_expires ON pwa_tokens(expires_at);
CREATE INDEX IF NOT EXISTS idx_pwa_tokens_token ON pwa_tokens(token);

-- Table pour logger tous les accès bureau
CREATE TABLE IF NOT EXISTS bureau_access_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bureau_id UUID NOT NULL REFERENCES bureaus(id) ON DELETE CASCADE,
  access_type TEXT NOT NULL,
  token_used TEXT,
  ip_address TEXT,
  user_agent TEXT,
  success BOOLEAN DEFAULT true,
  error_message TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Index pour logs
CREATE INDEX IF NOT EXISTS idx_bureau_access_logs_bureau ON bureau_access_logs(bureau_id);
CREATE INDEX IF NOT EXISTS idx_bureau_access_logs_timestamp ON bureau_access_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_bureau_access_logs_type ON bureau_access_logs(access_type);

-- Politiques RLS pour pwa_installations
ALTER TABLE pwa_installations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins peuvent tout voir" ON pwa_installations
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE profiles.id = auth.uid() 
      AND profiles.role = 'admin'
    )
  );

CREATE POLICY "Service role accès complet" ON pwa_installations
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Politiques RLS pour pwa_tokens
ALTER TABLE pwa_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins peuvent gérer les tokens" ON pwa_tokens
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE profiles.id = auth.uid() 
      AND profiles.role = 'admin'
    )
  );

CREATE POLICY "Service role accès complet tokens" ON pwa_tokens
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Politiques RLS pour bureau_access_logs
ALTER TABLE bureau_access_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins peuvent voir les logs" ON bureau_access_logs
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM profiles 
      WHERE profiles.id = auth.uid() 
      AND profiles.role = 'admin'
    )
  );

CREATE POLICY "Service role accès complet logs" ON bureau_access_logs
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Fonction pour nettoyer les tokens expirés
CREATE OR REPLACE FUNCTION cleanup_expired_tokens()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  DELETE FROM pwa_tokens
  WHERE expires_at < NOW() - INTERVAL '7 days';
END;
$$;

-- Fonction pour vérifier si un bureau a déjà une installation active
CREATE OR REPLACE FUNCTION has_active_installation(bureau_uuid UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  installation_count INTEGER;
BEGIN
  SELECT COUNT(*) INTO installation_count
  FROM pwa_installations
  WHERE bureau_id = bureau_uuid
  AND installed_at > NOW() - INTERVAL '30 days';
  
  RETURN installation_count > 0;
END;
$$;

-- Trigger pour marquer le token comme utilisé lors d'une installation
CREATE OR REPLACE FUNCTION mark_token_used()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE pwa_tokens
  SET used = true, used_at = NEW.installed_at
  WHERE token = NEW.token
  AND bureau_id = NEW.bureau_id;
  
  RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_mark_token_used
  AFTER INSERT ON pwa_installations
  FOR EACH ROW
  WHEN (NEW.token IS NOT NULL)
  EXECUTE FUNCTION mark_token_used();

-- Vue pour les statistiques PWA par bureau
CREATE OR REPLACE VIEW bureau_pwa_stats AS
SELECT 
  b.id as bureau_id,
  b.prefecture,
  b.commune,
  COUNT(DISTINCT pi.id) as total_installations,
  COUNT(DISTINCT CASE WHEN pi.installed_at > NOW() - INTERVAL '30 days' THEN pi.id END) as recent_installations,
  COUNT(DISTINCT CASE WHEN pi.is_mobile = true THEN pi.id END) as mobile_installations,
  COUNT(DISTINCT CASE WHEN pi.is_mobile = false THEN pi.id END) as desktop_installations,
  MAX(pi.installed_at) as last_installation,
  COUNT(DISTINCT pt.id) as total_tokens_generated,
  COUNT(DISTINCT CASE WHEN pt.used = true THEN pt.id END) as tokens_used,
  COUNT(DISTINCT bal.id) as total_access_attempts
FROM bureaus b
LEFT JOIN pwa_installations pi ON b.id = pi.bureau_id
LEFT JOIN pwa_tokens pt ON b.id = pt.bureau_id
LEFT JOIN bureau_access_logs bal ON b.id = bal.bureau_id
GROUP BY b.id, b.prefecture, b.commune;

-- Permissions sur la vue
GRANT SELECT ON bureau_pwa_stats TO authenticated;

COMMENT ON TABLE pwa_installations IS 'Suivi des installations PWA pour les bureaux syndicat';
COMMENT ON TABLE pwa_tokens IS 'Tokens JWT pour l''installation sécurisée des PWA';
COMMENT ON TABLE bureau_access_logs IS 'Logs d''accès complets pour les bureaux syndicat';
COMMENT ON VIEW bureau_pwa_stats IS 'Statistiques d''installation PWA par bureau';