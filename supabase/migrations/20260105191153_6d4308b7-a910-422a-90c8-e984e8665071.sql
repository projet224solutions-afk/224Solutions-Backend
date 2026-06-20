-- Créer une fonction security definer pour vérifier si un utilisateur est admin ou PDG
-- Cela évite la récursion et est plus sécurisé que d'utiliser user_metadata

CREATE OR REPLACE FUNCTION public.is_admin_or_pdg(user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM pdg_management WHERE pdg_management.user_id = $1 AND is_active = true
  )
$$;

-- Supprimer l'ancienne politique qui utilise user_metadata (non sécurisé)
DROP POLICY IF EXISTS "admins_can_view_all_profiles" ON public.profiles;

-- Recréer la politique en utilisant la fonction security definer
CREATE POLICY "admins_can_view_all_profiles" ON public.profiles 
FOR SELECT 
USING (
  id = auth.uid() 
  OR public.is_admin_or_pdg(auth.uid())
);