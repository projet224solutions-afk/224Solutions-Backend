-- ============================================================================
-- ⏪ REVERT URGENT — restaurer l'accès SELECT complet à profiles pour authenticated
-- ----------------------------------------------------------------------------
-- La migration 20260609120000 (REVOKE des colonnes email/kyc à authenticated)
-- a cassé la CONNEXION : useAuth.tsx charge le profil via select('*') (ligne 409,
-- 599, 614) et lit email (ligne 550) → ces requêtes renvoyaient 403 → le rôle ne
-- chargeait plus → « Accès non autorisé ». On REND l'accès complet immédiatement.
--
-- La fuite email/kyc (modérée) est ré-ouverte temporairement — préférable à un
-- verrouillage total des utilisateurs. Le bon correctif (repointer TOUTES les
-- lectures profiles, dont useAuth, vers des colonnes sûres + email via session,
-- AVANT de re-REVOKE) sera refait proprement et testé. Non destructif, rejouable.
-- ============================================================================

GRANT SELECT ON public.profiles TO authenticated;

SELECT 'profiles : SELECT complet restauré pour authenticated (login réparé).' AS status;
