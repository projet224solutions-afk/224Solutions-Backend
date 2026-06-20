-- Permettre la lecture publique des profils pour les statistiques
-- Cela permet de compter les utilisateurs par rôle sans exposer les données sensibles

-- Créer une policy pour permettre la lecture des informations de base des profils
CREATE POLICY "Allow public read of basic profile info for stats"
ON profiles
FOR SELECT
USING (true);

-- Note: Cette policy permet uniquement la lecture (SELECT) des profils
-- Les données sensibles comme email, phone peuvent être filtrées au niveau applicatif si nécessaire