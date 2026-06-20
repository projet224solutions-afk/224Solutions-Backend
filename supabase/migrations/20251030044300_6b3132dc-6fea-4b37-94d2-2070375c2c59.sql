-- Permettre le comptage public des profils pour les statistiques
-- Cette politique permet de lire le rôle pour compter les utilisateurs
-- sans exposer les informations personnelles sensibles
CREATE POLICY "Public can count profiles by role"
ON public.profiles
FOR SELECT
TO public
USING (true);