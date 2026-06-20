-- Supprimer la politique problématique qui cause une récursion infinie
DROP POLICY IF EXISTS "admins_can_view_all_profiles" ON public.profiles;

-- Recréer une politique admin qui utilise auth.jwt() au lieu de requêter profiles
-- Cela évite la récursion infinie
CREATE POLICY "admins_can_view_all_profiles" ON public.profiles 
FOR SELECT 
USING (
  id = auth.uid() 
  OR (auth.jwt() ->> 'email' IN (SELECT email FROM pdg_management WHERE is_active = true))
  OR ((auth.jwt() -> 'user_metadata' ->> 'role') = 'admin')
);