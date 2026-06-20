-- ============================================================================
-- 🔒 DURCISSEMENT — search_path fixe sur les fonctions (advisor function_search_path_mutable).
--
-- Une fonction sans `search_path` figé est vulnérable au détournement (un schéma malveillant
-- dans le search_path du caller peut faire exécuter de mauvais objets) — surtout pour les
-- fonctions SECURITY DEFINER. On fige `search_path = public, extensions, pg_temp` :
--   • public     : objets applicatifs,
--   • extensions : PostGIS/pgcrypto/etc. (gen_random_uuid…) → ne casse pas les fonctions qui les
--                  appellent sans préfixe,
--   • pg_temp en DERNIER : recommandé (empêche le hijack via tables temporaires).
--
-- EXCLUSIONS : fonctions appartenant à une EXTENSION (PostGIS, pg_net…) — non modifiables et hors
-- de notre responsabilité. Couvre FUNCTION et PROCEDURE. ATOMIQUE, IDEMPOTENT (ne touche que
-- celles sans search_path), per-fonction EXCEPTION (une non modifiable n'arrête pas la boucle).
-- ============================================================================

DO $$
DECLARE
  r       record;
  v_done  int := 0;
  v_skip  int := 0;
BEGIN
  FOR r IN
    SELECT p.oid,
           p.proname,
           p.prokind,
           pg_get_function_identity_arguments(p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind IN ('f', 'p')         -- fonctions + procédures (pas agrégats/window)
      AND NOT EXISTS (
        SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) cfg WHERE cfg LIKE 'search_path=%'
      )
      -- Exclure les fonctions membres d'une extension (PostGIS, pg_net…)
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e'
      )
    ORDER BY p.proname
  LOOP
    BEGIN
      EXECUTE format(
        'ALTER %s public.%I(%s) SET search_path = public, extensions, pg_temp;',
        CASE WHEN r.prokind = 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
        r.proname, r.args
      );
      v_done := v_done + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '⏭️  Ignorée (%): public.%(%)', SQLERRM, r.proname, r.args;
      v_skip := v_skip + 1;
    END;
  END LOOP;
  RAISE NOTICE '✅ Fonctions durcies (search_path figé) : % | ignorées : %', v_done, v_skip;
END $$;

-- Diagnostic : fonctions NON-extension encore sans search_path (doit être ~0 après).
SELECT 'FONCTIONS (hors extension) ENCORE SANS search_path' AS verif, count(*)::text AS n
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p')
  AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}')) cfg WHERE cfg LIKE 'search_path=%')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e');
