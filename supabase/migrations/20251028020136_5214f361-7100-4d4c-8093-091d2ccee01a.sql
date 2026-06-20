-- Ajouter le champ access_token à la table agents_management
ALTER TABLE agents_management 
ADD COLUMN IF NOT EXISTS access_token TEXT UNIQUE;

-- Créer un index sur access_token pour des recherches rapides
CREATE INDEX IF NOT EXISTS idx_agents_access_token ON agents_management(access_token);

-- Fonction pour générer un token d'accès unique pour un agent
CREATE OR REPLACE FUNCTION generate_agent_access_token()
RETURNS TEXT AS $$
DECLARE
  new_token TEXT;
  token_exists BOOLEAN;
BEGIN
  LOOP
    -- Générer un token aléatoire de 32 caractères
    new_token := encode(gen_random_bytes(24), 'base64');
    new_token := replace(replace(replace(new_token, '/', '_'), '+', '-'), '=', '');
    
    -- Vérifier si le token existe déjà
    SELECT EXISTS(SELECT 1 FROM agents_management WHERE access_token = new_token) INTO token_exists;
    
    -- Si le token n'existe pas, on le retourne
    IF NOT token_exists THEN
      RETURN new_token;
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Générer des tokens pour les agents existants qui n'en ont pas
UPDATE agents_management 
SET access_token = generate_agent_access_token()
WHERE access_token IS NULL;

-- Trigger pour générer automatiquement un token lors de la création d'un agent
CREATE OR REPLACE FUNCTION set_agent_access_token()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.access_token IS NULL THEN
    NEW.access_token := generate_agent_access_token();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_set_agent_access_token ON agents_management;
CREATE TRIGGER trigger_set_agent_access_token
  BEFORE INSERT ON agents_management
  FOR EACH ROW
  EXECUTE FUNCTION set_agent_access_token();