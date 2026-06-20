-- ============================================================================
-- NETTOYAGE — suppression des tables de l'ANCIEN 2FA client-side (non fonctionnel)
-- ----------------------------------------------------------------------------
-- Contexte : l'ancien 2FA (hook useTwoFactorAuth + TwoFactorSetup + AdvancedMFA +
-- edge function verify-totp) vérifiait le TOTP DANS LE NAVIGATEUR (contournable) et
-- stockait un secret chiffré avec l'UUID public. Tout ce code a été supprimé et
-- remplacé par le step-up TOTP vérifié SERVEUR (table admin_mfa, migration
-- 20260614120000). Ces 2 tables ne sont plus référencées par aucun code.
--
-- Contenu au moment du nettoyage : totp_verification_attempts = 0 ligne,
-- user_2fa_settings = 1 ligne (secret désormais inopérant). Aucune perte de sécurité.
--
-- Sans CASCADE : si un objet dépend encore d'une table, le DROP échoue PROPREMENT
-- (au lieu de supprimer en chaîne) → prévenir et investiguer le cas échéant.
-- ============================================================================

DROP TABLE IF EXISTS public.totp_verification_attempts;
DROP TABLE IF EXISTS public.user_2fa_settings;

SELECT 'Tables ancien 2FA client-side supprimées (totp_verification_attempts, user_2fa_settings).' AS status;
