-- ============================================================================
-- 🔒 SÉCURITÉ CRITIQUE — RLS sur TOUTES les tables publiques (advisor rls_disabled_in_public).
--
-- Supabase a détecté ≥1 table du schéma `public` SANS Row Level Security : lisible/modifiable
-- /supprimable par quiconque possède la clé anon. On active RLS sur CHAQUE table publique qui
-- ne l'a pas → par défaut « deny all » : aucun accès anon/authenticated tant qu'aucune policy
-- ne l'autorise (le service_role/backend, qui a BYPASSRLS, continue d'accéder normalement).
--
-- ATOMIQUE, IDEMPOTENT, NON DESTRUCTIF (n'ajoute/ne supprime aucune policy existante).
--
-- ⛔ EXCLUSIONS : tables appartenant à une EXTENSION (ex. PostGIS `spatial_ref_sys`) — on n'en
--    est pas propriétaire (ALTER interdit) et ce sont des données de référence non sensibles.
--    Chaque ALTER est aussi protégé par un sous-bloc EXCEPTION → une table non modifiable est
--    ignorée sans interrompre la sécurisation des autres.
-- ============================================================================

DO $$
DECLARE
  r       record;
  v_done  int := 0;
  v_skip  int := 0;
BEGIN
  FOR r IN
    SELECT c.oid, c.relname AS tbl
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p')        -- tables ordinaires + partitionnées
      AND c.relrowsecurity = false        -- RLS désactivé
      -- Exclure les tables membres d'une extension (PostGIS, etc.)
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e'
      )
    ORDER BY c.relname
  LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY;', r.tbl);
      RAISE NOTICE '🔒 RLS activé sur public.% (verrouillée tant qu''aucune policy ne l''ouvre)', r.tbl;
      v_done := v_done + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '⏭️  Ignorée (non modifiable : %) — public.%', SQLERRM, r.tbl;
      v_skip := v_skip + 1;
    END;
  END LOOP;
  RAISE NOTICE '✅ Tables sécurisées : % | ignorées (extension/non-propriétaire) : %', v_done, v_skip;
END $$;

-- Diagnostic 1 : tables publiques SANS RLS, hors extensions (doit être vide après exécution).
SELECT 'TABLES ENCORE SANS RLS (doit être vide)' AS verif, c.relname AS table_name
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relrowsecurity = false
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
ORDER BY c.relname;

-- Diagnostic 2 : tables RLS activé MAIS SANS policy = verrouillées (accès backend/service_role
-- uniquement). À examiner : si l'une doit être lisible côté client, on lui ajoutera une policy scopée.
SELECT 'TABLES VERROUILLÉES SANS POLICY (à examiner si front en a besoin)' AS verif, c.relname AS table_name
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND c.relrowsecurity = true
  AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid)
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
ORDER BY c.relname;
