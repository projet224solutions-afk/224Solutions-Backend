-- ============================================================================
-- ALTER AGENTS TABLE - 224SOLUTIONS
-- Ajout des colonnes pour authentification sécurisée + MFA
-- ============================================================================

-- Ajouter password_hash (si n'existe pas déjà)
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agents' AND column_name = 'password_hash'
  ) THEN
    ALTER TABLE agents ADD COLUMN password_hash TEXT;
  END IF;
END $$;

-- Ajouter failed_login_attempts
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agents' AND column_name = 'failed_login_attempts'
  ) THEN
    ALTER TABLE agents ADD COLUMN failed_login_attempts INT DEFAULT 0;
  END IF;
END $$;

-- Ajouter locked_until (verrouillage temporaire après 5 tentatives)
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agents' AND column_name = 'locked_until'
  ) THEN
    ALTER TABLE agents ADD COLUMN locked_until TIMESTAMPTZ;
  END IF;
END $$;

-- Ajouter last_login
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'agents' AND column_name = 'last_login'
  ) THEN
    ALTER TABLE agents ADD COLUMN last_login TIMESTAMPTZ;
  END IF;
END $$;

-- Index pour recherche rapide par email ou phone
CREATE INDEX IF NOT EXISTS idx_agents_email ON agents(email);
CREATE INDEX IF NOT EXISTS idx_agents_phone ON agents(phone);

-- Commentaires
COMMENT ON COLUMN agents.password_hash IS 'Mot de passe hashé avec bcrypt';
COMMENT ON COLUMN agents.failed_login_attempts IS 'Nombre de tentatives de connexion échouées';
COMMENT ON COLUMN agents.locked_until IS 'Date de fin du verrouillage (après 5 tentatives échouées)';
COMMENT ON COLUMN agents.last_login IS 'Date de dernière connexion réussie';

-- ============================================================================
-- ALTER SYNDICATE_BUREAUS TABLE - 224SOLUTIONS
-- Ajout des colonnes pour authentification sécurisée + MFA
-- ============================================================================

-- Ajouter password_hash (si n'existe pas déjà)
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'syndicate_bureaus' AND column_name = 'password_hash'
  ) THEN
    ALTER TABLE syndicate_bureaus ADD COLUMN password_hash TEXT;
  END IF;
END $$;

-- Ajouter failed_login_attempts
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'syndicate_bureaus' AND column_name = 'failed_login_attempts'
  ) THEN
    ALTER TABLE syndicate_bureaus ADD COLUMN failed_login_attempts INT DEFAULT 0;
  END IF;
END $$;

-- Ajouter locked_until
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'syndicate_bureaus' AND column_name = 'locked_until'
  ) THEN
    ALTER TABLE syndicate_bureaus ADD COLUMN locked_until TIMESTAMPTZ;
  END IF;
END $$;

-- Ajouter last_login
DO $$ 
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_name = 'syndicate_bureaus' AND column_name = 'last_login'
  ) THEN
    ALTER TABLE syndicate_bureaus ADD COLUMN last_login TIMESTAMPTZ;
  END IF;
END $$;

-- Index pour recherche rapide par president_email ou president_phone
CREATE INDEX IF NOT EXISTS idx_bureaus_president_email ON syndicate_bureaus(president_email);
CREATE INDEX IF NOT EXISTS idx_bureaus_president_phone ON syndicate_bureaus(president_phone);

-- Commentaires
COMMENT ON COLUMN syndicate_bureaus.password_hash IS 'Mot de passe hashé avec bcrypt';
COMMENT ON COLUMN syndicate_bureaus.failed_login_attempts IS 'Nombre de tentatives de connexion échouées';
COMMENT ON COLUMN syndicate_bureaus.locked_until IS 'Date de fin du verrouillage (après 5 tentatives échouées)';
COMMENT ON COLUMN syndicate_bureaus.last_login IS 'Date de dernière connexion réussie';
