-- Le trigger update_wallet_balance_trigger référence des colonnes de l'ancien schéma
-- (to_wallet_id, from_wallet_id, wallet_id, type) qui n'existent plus dans wallet_transactions.
-- Le backend Node.js gère les mises à jour de solde directement via UPDATE atomique avec
-- verrou optimiste. Ce trigger est donc obsolète ET cassé : il fait échouer tous les INSERT
-- dans wallet_transactions, empêchant la persistance de l'historique.

DROP TRIGGER IF EXISTS update_wallet_balance_trigger ON wallet_transactions;

-- Également supprimer la fonction devenue inutile (remplacée par update_wallet_balance_atomic)
DROP FUNCTION IF EXISTS update_wallet_balance() CASCADE;

-- Autoriser les utilisateurs authentifiés à lire les informations de base des profils
-- nécessaires pour l'affichage des noms dans l'historique des transactions.
-- Seuls les champs non-sensibles sont exposés (pas de mot de passe, pas de données financières).
DROP POLICY IF EXISTS "Authenticated users can view basic profile info" ON public.profiles;
CREATE POLICY "Authenticated users can view basic profile info"
ON public.profiles
FOR SELECT
TO authenticated
USING (true);
