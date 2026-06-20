-- =====================================================================
-- SUPPRESSION DU SYSTÈME D'API VENDEUR (fonctionnalité fantôme)
-- =====================================================================
-- Contexte : « Accès API » était annoncé dans les plans d'abonnement mais
-- aucun système réel ne l'exploitait :
--   - le composant ApiKeyManager.tsx n'était importé nulle part (code mort, supprimé)
--   - aucune route backend n'authentifie les clés `api_keys`
--     (les seules clés backend sont internes : x-internal-api-key, sync, IA)
--   - la table `api_keys` contient 0 ligne
--
-- La fonctionnalité a été retirée du code et des descriptions de plans.
-- Ce script supprime les orphelins restants en base (DDL — à exécuter
-- dans Supabase Dashboard → SQL Editor → Run). Idempotent.
-- =====================================================================

-- 1. Supprimer toutes les signatures de la fonction generate_api_key()
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT oid::regprocedure AS sig
    FROM pg_proc
    WHERE proname = 'generate_api_key'
      AND pronamespace = 'public'::regnamespace
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END $$;

-- 2. Supprimer la table des clés API (avec policies / index / contraintes dépendantes)
DROP TABLE IF EXISTS public.api_keys CASCADE;

-- Note : la colonne booléenne `plans.api_access` est conservée (déjà mise à
-- false partout) ; elle n'est plus affichée ni utilisée pour le gating.
