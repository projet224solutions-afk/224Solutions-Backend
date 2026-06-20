-- Ajouter une politique pour permettre aux admins/PDG de voir tous les vendeurs
-- D'abord vérifier si une politique existe déjà pour les admins sur profiles

-- Politique pour voir tous les vendeurs (role = 'vendeur') pour les admins
CREATE POLICY "admins_can_view_all_vendors" 
ON public.profiles 
FOR SELECT 
USING (
  -- Soit c'est un admin connecté
  EXISTS (
    SELECT 1 FROM profiles p 
    WHERE p.id = auth.uid() 
    AND p.role = 'admin'::user_role
  )
  -- Ou l'utilisateur est un PDG dans pdg_management
  OR EXISTS (
    SELECT 1 FROM pdg_management 
    WHERE pdg_management.user_id = auth.uid()
  )
  -- Ou c'est son propre profil
  OR id = auth.uid()
);