-- Supprimer les anciennes politiques RLS restrictives
DROP POLICY IF EXISTS "Bureau workers can view their own bureau workers" ON syndicate_workers;
DROP POLICY IF EXISTS "Bureau workers can insert" ON syndicate_workers;
DROP POLICY IF EXISTS "Bureau workers can update" ON syndicate_workers;
DROP POLICY IF EXISTS "Bureau workers can delete" ON syndicate_workers;
DROP POLICY IF EXISTS "Authenticated users can view syndicate workers" ON syndicate_workers;

-- Créer des politiques RLS permissives pour SELECT (les modifications passent par SECURITY DEFINER)
CREATE POLICY "Allow authenticated users to read syndicate workers"
ON syndicate_workers FOR SELECT
TO authenticated
USING (true);

-- Permettre les insertions via les fonctions SECURITY DEFINER uniquement
CREATE POLICY "Allow service role full access to syndicate workers"
ON syndicate_workers FOR ALL
TO service_role
USING (true)
WITH CHECK (true);