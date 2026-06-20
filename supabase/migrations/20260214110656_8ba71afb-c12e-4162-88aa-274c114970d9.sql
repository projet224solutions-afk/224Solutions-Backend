
-- Remplacer cleanup_user_references par une version dynamique et sûre
CREATE OR REPLACE FUNCTION public.cleanup_user_references(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  rec record;
  stmt text;
BEGIN
  -- Mettre à NULL uniquement les FKs NULLABLE vers auth.users (public schema)
  FOR rec IN
    SELECT
      n.nspname AS schema_name,
      c.relname AS table_name,
      a.attname AS column_name,
      t.typname AS type_name,
      (NOT a.attnotnull) AS is_nullable
    FROM pg_constraint con
    JOIN pg_class c ON con.conrelid = c.oid
    JOIN pg_namespace n ON c.relnamespace = n.oid
    JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = ANY(con.conkey)
    JOIN pg_type t ON a.atttypid = t.oid
    WHERE con.confrelid = 'auth.users'::regclass
      AND con.contype = 'f'
      AND n.nspname = 'public'
  LOOP
    IF rec.is_nullable THEN
      BEGIN
        IF rec.type_name = 'uuid' THEN
          stmt := format(
            'UPDATE %I.%I SET %I = NULL WHERE %I = $1',
            rec.schema_name, rec.table_name, rec.column_name, rec.column_name
          );
          EXECUTE stmt USING target_user_id;
        ELSIF rec.type_name IN ('text', 'varchar', 'bpchar') THEN
          stmt := format(
            'UPDATE %I.%I SET %I = NULL WHERE %I = $1::text',
            rec.schema_name, rec.table_name, rec.column_name, rec.column_name
          );
          EXECUTE stmt USING target_user_id;
        ELSE
          -- Fallback: comparaison text pour éviter les mismatches de type
          stmt := format(
            'UPDATE %I.%I SET %I = NULL WHERE %I::text = $1::text',
            rec.schema_name, rec.table_name, rec.column_name, rec.column_name
          );
          EXECUTE stmt USING target_user_id;
        END IF;
      EXCEPTION WHEN undefined_table THEN
        -- Table supprimée ou non présente selon environnement
        NULL;
      WHEN undefined_column THEN
        NULL;
      WHEN others THEN
        -- On ne bloque pas la suppression pour un champ non critique
        NULL;
      END;
    END IF;
  END LOOP;
END;
$$;

-- Corriger delete_user_storage_objects pour supporter owner_id text OU uuid
CREATE OR REPLACE FUNCTION public.delete_user_storage_objects(target_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
BEGIN
  -- 1) Cas standard (owner_id uuid)
  BEGIN
    DELETE FROM storage.objects WHERE owner_id = target_user_id;
    RETURN;
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  -- 2) Cas owner_id text
  BEGIN
    DELETE FROM storage.objects WHERE owner_id = target_user_id::text;
    RETURN;
  EXCEPTION WHEN undefined_function THEN
    NULL;
  END;

  -- 3) Cas owner_id text mais castable en uuid
  BEGIN
    DELETE FROM storage.objects WHERE owner_id::uuid = target_user_id;
  EXCEPTION WHEN invalid_text_representation THEN
    NULL;
  WHEN undefined_column THEN
    NULL;
  WHEN others THEN
    NULL;
  END;
END;
$$;
