-- Supprimer les anciennes politiques RLS
DROP POLICY IF EXISTS "Bureaus can create ticket batches" ON transport_ticket_batches;
DROP POLICY IF EXISTS "Bureaus can view own ticket batches" ON transport_ticket_batches;
DROP POLICY IF EXISTS "Admins can view all ticket batches" ON transport_ticket_batches;

-- Créer une fonction SECURITY DEFINER pour vérifier si un bureau existe
CREATE OR REPLACE FUNCTION public.bureau_exists(p_bureau_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM bureaus WHERE id = p_bureau_id
  )
$$;

-- Nouvelle politique INSERT: permettre l'insertion si le bureau_id correspond à un bureau existant
-- (la validation se fait au niveau applicatif car les bureaux utilisent une auth personnalisée)
CREATE POLICY "Allow bureau ticket batch creation"
ON transport_ticket_batches
FOR INSERT
TO public
WITH CHECK (
  public.bureau_exists(bureau_id)
);

-- Nouvelle politique SELECT: permettre la lecture des lots d'un bureau
CREATE POLICY "Allow bureau ticket batch viewing"
ON transport_ticket_batches
FOR SELECT
TO public
USING (
  public.bureau_exists(bureau_id)
);

-- Politique admin inchangée avec fonction existante
CREATE POLICY "Admins can view all ticket batches"
ON transport_ticket_batches
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE profiles.id = auth.uid() 
    AND profiles.role = 'admin'::user_role
  )
);