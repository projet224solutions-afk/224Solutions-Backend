-- Ajouter une policy INSERT pour profiles pour permettre au service_role de créer des profils
DROP POLICY IF EXISTS "service_role_can_insert_profiles" ON public.profiles;

CREATE POLICY "service_role_can_insert_profiles"
ON public.profiles
FOR INSERT
TO authenticated
WITH CHECK (
  auth.role() = 'service_role'
  OR auth.uid() = id
);

-- Commentaire
COMMENT ON POLICY "service_role_can_insert_profiles" ON public.profiles IS 
'Permet au service_role et aux utilisateurs de créer leur propre profil';