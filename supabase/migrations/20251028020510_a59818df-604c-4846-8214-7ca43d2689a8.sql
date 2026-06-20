-- Ajouter une politique RLS pour permettre l'accès public aux agents via leur access_token
CREATE POLICY "Anyone can view agent with valid access_token"
ON agents_management
FOR SELECT
USING (access_token IS NOT NULL);