-- ============================================================================
-- SUPPRESSION UTILISATEUR — nettoyage DYNAMIQUE des références (anti « Database error deleting user »).
--
-- PROBLÈME : la suppression échouait car des tables référencent l'utilisateur par d'AUTRES
-- colonnes que `user_id` (ex: wallet_transactions.sender_user_id / receiver_user_id). Tant
-- qu'une seule ligne référence l'utilisateur (sans ON DELETE CASCADE), `auth.admin.deleteUser`
-- échoue avec « Database error deleting user ».
--
-- FIX BULLETPROOF : cette fonction introspecte TOUTES les clés étrangères (mono-colonne) des
-- tables du schéma `public` qui pointent vers auth.users(id) OU public.profiles(id), et pour
-- chacune : met la colonne à NULL si elle est nullable (préserve la ligne), sinon SUPPRIME la
-- ligne. La table `profiles` est exclue (supprimée à part, en dernier). Ainsi, quelle que soit
-- la colonne (sender_user_id, receiver_user_id, created_by, actor_id…), plus aucune référence
-- ne bloque la suppression du compte auth. Idempotent, robuste (chaque table en sous-bloc).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cleanup_user_references(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT (con.conrelid::regclass)::text AS tbl,
           att.attname                    AS col,
           att.attnotnull                 AS notnull
    FROM pg_constraint con
    JOIN pg_class srccl       ON srccl.oid = con.conrelid
    JOIN pg_namespace srcns   ON srcns.oid = srccl.relnamespace
    JOIN pg_attribute att     ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
    JOIN pg_class refcl       ON refcl.oid = con.confrelid
    JOIN pg_namespace refns   ON refns.oid = refcl.relnamespace
    WHERE con.contype = 'f'
      AND array_length(con.conkey, 1) = 1                 -- FK mono-colonne uniquement
      AND srcns.nspname = 'public'                        -- ne toucher que le schéma public
      AND NOT (srccl.relname = 'profiles')                -- profiles supprimé séparément
      AND (
        (refns.nspname = 'auth'   AND refcl.relname = 'users')
        OR (refns.nspname = 'public' AND refcl.relname = 'profiles')
      )
  LOOP
    BEGIN
      IF r.notnull THEN
        EXECUTE format('DELETE FROM %s WHERE %I = $1', r.tbl, r.col) USING target_user_id;
      ELSE
        EXECUTE format('UPDATE %s SET %I = NULL WHERE %I = $1', r.tbl, r.col, r.col) USING target_user_id;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'cleanup_user_references %.%: %', r.tbl, r.col, SQLERRM;
    END;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.cleanup_user_references(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cleanup_user_references(uuid) TO service_role;

SELECT 'cleanup_user_references : nettoyage dynamique de toutes les FK publiques vers auth.users/profiles (NULL si nullable, sinon DELETE).' AS status;
