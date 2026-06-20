-- ============================================================================
-- 🩹 CORRECTIF — ré-aplatir les policies double-enveloppées `(select (select auth.X()))`.
--
-- Une tentative d'optimisation `auth_rls_initplan` (migration 20260617230000, supprimée) a
-- double-enveloppé quelques policies dont l'appel auth.X() était DÉJÀ optimisé sous la forme
-- normalisée par Postgres `( SELECT auth.uid() AS uid)`. Résultat : `( SELECT (select auth.uid())
-- AS uid)` — sémantiquement identique (aucune faille), mais à nettoyer.
--
-- FIX : on retire la couche INTERNE `(select auth.X())` (sans alias) → il reste la forme optimale
-- `( SELECT auth.uid() AS uid)`. Ne touche QUE les policies double-enveloppées, EXCEPTION par
-- policy (jamais de casse). ATOMIQUE, IDEMPOTENT.
-- ============================================================================

DO $$
DECLARE
  pol      record;
  v_using  text;
  v_check  text;
  v_done   int := 0;
  -- Double wrap COMPLET (Postgres ajoute un alias `AS uid` aux DEUX couches) :
  -- `( SELECT ( SELECT auth.uid() AS uid) AS uid)` → on le collapse en `(select auth.uid())`.
  re_double text := '\(\s*select\s+\(\s*select\s+(auth\.(uid|role|jwt|email)\(\))(\s+as\s+\w+)?\s*\)(\s+as\s+\w+)?\s*\)';
BEGIN
  FOR pol IN
    SELECT p.polname, c.relname AS tbl,
           pg_get_expr(p.polqual, p.polrelid)      AS using_expr,
           pg_get_expr(p.polwithcheck, p.polrelid) AS check_expr
    FROM pg_policy p
    JOIN pg_class c     ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND (
        pg_get_expr(p.polqual, p.polrelid)      ~* '\(\s*select\s+\(\s*select\s+auth\.(uid|role|jwt|email)'
        OR pg_get_expr(p.polwithcheck, p.polrelid) ~* '\(\s*select\s+\(\s*select\s+auth\.(uid|role|jwt|email)'
      )
  LOOP
    v_using := pol.using_expr;
    v_check := pol.check_expr;
    IF v_using IS NOT NULL THEN v_using := regexp_replace(v_using, re_double, '(select \1)', 'gi'); END IF;
    IF v_check IS NOT NULL THEN v_check := regexp_replace(v_check, re_double, '(select \1)', 'gi'); END IF;

    BEGIN
      IF v_using IS NOT NULL AND v_check IS NOT NULL THEN
        EXECUTE format('ALTER POLICY %I ON public.%I USING (%s) WITH CHECK (%s);', pol.polname, pol.tbl, v_using, v_check);
      ELSIF v_using IS NOT NULL THEN
        EXECUTE format('ALTER POLICY %I ON public.%I USING (%s);', pol.polname, pol.tbl, v_using);
      ELSIF v_check IS NOT NULL THEN
        EXECUTE format('ALTER POLICY %I ON public.%I WITH CHECK (%s);', pol.polname, pol.tbl, v_check);
      END IF;
      v_done := v_done + 1;
      RAISE NOTICE '🩹 Ré-aplatie : % ON public.%', pol.polname, pol.tbl;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE '⏭️  Laissée intacte (%) : % ON public.%', SQLERRM, pol.polname, pol.tbl;
    END;
  END LOOP;
  RAISE NOTICE '✅ Policies ré-aplaties : %', v_done;
END $$;

-- Diagnostic : plus aucune policy double-enveloppée (doit être 0).
SELECT 'POLICIES DOUBLE-ENVELOPPÉES RESTANTES (doit être 0)' AS verif, count(*)::text AS n
FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND (
    pg_get_expr(p.polqual,p.polrelid)      ~* '\(\s*select\s+\(\s*select\s+auth\.(uid|role|jwt|email)'
    OR pg_get_expr(p.polwithcheck,p.polrelid) ~* '\(\s*select\s+\(\s*select\s+auth\.(uid|role|jwt|email)'
  );
