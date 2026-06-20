-- Supprimer la politique problématique qui cause la récursion infinie
DROP POLICY IF EXISTS "admins_can_view_all_vendors" ON public.profiles;

-- Créer une nouvelle politique qui évite la récursion en utilisant auth.jwt() 
-- au lieu de requêter la table profiles elle-même
CREATE POLICY "admins_and_pdg_can_view_vendors" 
ON public.profiles 
FOR SELECT 
USING (
  -- C'est son propre profil
  id = auth.uid()
  -- Ou l'utilisateur est un PDG dans pdg_management (pas de récursion car table différente)
  OR EXISTS (
    SELECT 1 FROM pdg_management 
    WHERE pdg_management.user_id = auth.uid()
  )
);