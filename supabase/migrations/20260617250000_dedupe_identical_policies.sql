-- ============================================================================
-- ⚡ PERF/PROPRETÉ — suppression des policies permissives EXACTEMENT identiques (doublons).
--
-- advisor `multiple_permissive_policies` : plusieurs policies permissives sur la même action
-- → Postgres les évalue toutes. Beaucoup sont de purs DOUBLONS (même action, mêmes rôles, même
-- USING, même WITH CHECK) issus de migrations rejouées sous des noms différents.
--
-- On ne supprime QUE les copies STRICTEMENT identiques (on garde la 1re par ordre de nom) →
-- AUCUN changement de logique de sécurité (la policy conservée est identique aux supprimées).
-- Les policies aux conditions DIFFÉRENTES (owner/admin/pdg…) ne sont PAS touchées.
-- ATOMIQUE, IDEMPOTENT, EXCEPTION par policy.
-- ============================================================================

DO $$
DECLARE
  r          record;
  v_dropped  int := 0;
BEGIN
  FOR r IN
    SELECT c.relname AS tbl, p.polname,
           row_number() OVER (
             PARTITION BY p.polrelid, p.polcmd, p.polpermissive, p.polroles,
                          coalesce(pg_get_expr(p.polqual, p.polrelid), ''),
                          coalesce(pg_get_expr(p.polwithcheck, p.polrelid), '')
             ORDER BY p.polname
           ) AS rn
    FROM pg_policy p
    JOIN pg_class c     ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND p.polpermissive
  LOOP
    IF r.rn > 1 THEN   -- doublon exact (une copie identique existe déjà, conservée)
      BEGIN
        EXECUTE format('DROP POLICY %I ON public.%I;', r.polname, r.tbl);
        v_dropped := v_dropped + 1;
        RAISE NOTICE '🗑️  Doublon exact supprimé : % ON public.%', r.polname, r.tbl;
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '⏭️  Non supprimée (%) : % ON public.%', SQLERRM, r.polname, r.tbl;
      END;
    END IF;
  END LOOP;
  RAISE NOTICE '✅ Doublons exacts supprimés : %', v_dropped;
END $$;

-- Diagnostic : (table, action) ayant ENCORE >1 policy permissive (= vrais cas multi-conditions
-- à examiner manuellement, ou doublons non strictement identiques).
SELECT 'RESTE (table,action) >1 policy permissive' AS verif, count(*)::text AS n
FROM (
  SELECT p.polrelid, p.polcmd
  FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND p.polpermissive
  GROUP BY p.polrelid, p.polcmd HAVING count(*) > 1
) z;
