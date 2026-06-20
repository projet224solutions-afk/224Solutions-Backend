-- Ajouter une politique pour permettre aux utilisateurs authentifiés 
-- de rechercher d'autres utilisateurs (informations de base pour messagerie)
CREATE POLICY "users_can_search_profiles_for_messaging"
ON public.profiles
FOR SELECT
TO authenticated
USING (true);

-- Note: Cette politique permet de voir les profils pour la fonctionnalité de messagerie
-- Les données sensibles comme les mots de passe ne sont pas dans cette table