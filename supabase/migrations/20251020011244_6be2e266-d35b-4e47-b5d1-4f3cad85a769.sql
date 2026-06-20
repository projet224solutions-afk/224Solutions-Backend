-- Corriger les RLS policies pour syndicate_workers

-- Supprimer les anciennes policies si elles existent
DROP POLICY IF EXISTS "Bureau can manage workers" ON syndicate_workers;
DROP POLICY IF EXISTS "Workers can view their profile" ON syndicate_workers;
DROP POLICY IF EXISTS "Anyone can read workers with valid token" ON syndicate_workers;

-- Créer les nouvelles policies
-- 1. Permettre aux bureaux de gérer leurs travailleurs (via access_token du bureau)
CREATE POLICY "Bureau can manage workers"
ON syndicate_workers
FOR ALL
USING (
  EXISTS (
    SELECT 1 FROM bureaus 
    WHERE bureaus.id = syndicate_workers.bureau_id
    AND bureaus.access_token IS NOT NULL
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM bureaus 
    WHERE bureaus.id = syndicate_workers.bureau_id
    AND bureaus.access_token IS NOT NULL
  )
);

-- 2. Permettre la lecture publique pour les travailleurs avec un access_token valide
CREATE POLICY "Public read with valid token"
ON syndicate_workers
FOR SELECT
USING (access_token IS NOT NULL);

-- 3. Permettre au service_role de tout faire
CREATE POLICY "service_role_all"
ON syndicate_workers
FOR ALL
USING (auth.role() = 'service_role')
WITH CHECK (auth.role() = 'service_role');

-- Activer RLS sur la table
ALTER TABLE syndicate_workers ENABLE ROW LEVEL SECURITY;