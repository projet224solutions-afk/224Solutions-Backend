-- ============================================================================
-- 🔒 SÉCURITÉ — vues en SECURITY DEFINER exposées à l'anon (advisor security_definer_view).
--
-- 4 vues d'agrégats SENSIBLES (commissions, paiements, actionnaires) tournaient en SECURITY
-- DEFINER (privilèges du créateur → bypass RLS) ET étaient lisibles par l'anon → fuite : toute
-- personne avec la clé anon pouvait lire ces statistiques.
--
-- CORRECTIF :
--   1) security_invoker = on  → la vue s'exécute avec les droits du LECTEUR (respecte la RLS).
--   2) REVOKE anon/PUBLIC      → l'anon ne peut plus interroger la vue (défense en profondeur).
--   3) GRANT authenticated/service_role → le backend (service_role, BYPASSRLS) continue de lire ;
--      un PDG authentifié ne verra que ce que la RLS sous-jacente autorise.
--
-- Vérifié : 0 lecture frontend directe de ces vues ; les 2 utilisées le sont par le backend
-- (shareholders.routes via service_role) → AUCUNE casse. Atomique, idempotent.
-- NB : geography_columns / geometry_columns (PostGIS) ne sont PAS touchées (vues système d'une
-- extension, non modifiables, métadonnées non sensibles → fausse alerte ignorable).
-- ============================================================================

DO $$
DECLARE
  v      text;
  views  text[] := ARRAY[
    'agent_commission_stats',
    'payment_methods_stats',
    'shareholder_pdg_stats',
    'shareholder_percentage_summary'
  ];
BEGIN
  FOREACH v IN ARRAY views LOOP
    IF EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relname = v AND c.relkind = 'v'
    ) THEN
      EXECUTE format('ALTER VIEW public.%I SET (security_invoker = on);', v);
      EXECUTE format('REVOKE ALL ON public.%I FROM anon;', v);
      EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC;', v);
      EXECUTE format('GRANT SELECT ON public.%I TO authenticated, service_role;', v);
      RAISE NOTICE '🔒 Vue durcie : public.% (security_invoker=on, anon révoqué)', v;
    ELSE
      RAISE NOTICE '⏭️  Vue absente, ignorée : public.%', v;
    END IF;
  END LOOP;
END $$;

-- Diagnostic : vues publiques encore SANS security_invoker, HORS extensions (doit ne plus lister
-- que d'éventuelles vues PostGIS non modifiables).
SELECT 'VUES ENCORE SANS security_invoker (hors nos 4)' AS verif, c.relname AS vue,
       has_table_privilege('anon', c.oid, 'SELECT') AS lisible_anon
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'v'
  AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(c.reloptions, '{}')) o
                  WHERE o ILIKE 'security_invoker=true' OR o ILIKE 'security_invoker=on' OR o ILIKE 'security_invoker=1')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_class'::regclass AND d.objid=c.oid AND d.deptype='e')
ORDER BY c.relname;
