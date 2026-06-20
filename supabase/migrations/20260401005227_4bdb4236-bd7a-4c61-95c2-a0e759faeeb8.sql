-- Fix all FK constraints referencing auth.users that lack ON DELETE behavior
-- This prevents "Database error deleting user" when deleting via auth.admin.deleteUser

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT
      conrelid::regclass::text AS table_name,
      conname AS constraint_name,
      a.attname AS column_name
    FROM pg_constraint c
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
    WHERE c.confrelid = 'auth.users'::regclass
      AND c.contype = 'f'
      AND pg_get_constraintdef(c.oid) NOT LIKE '%CASCADE%'
      AND pg_get_constraintdef(c.oid) NOT LIKE '%SET NULL%'
      AND conrelid::regclass::text NOT LIKE 'auth.%'
  LOOP
    EXECUTE format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I', r.table_name, r.constraint_name);
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES auth.users(id) ON DELETE SET NULL', r.table_name, r.constraint_name, r.column_name);
    RAISE NOTICE 'Fixed: %.% (%)', r.table_name, r.column_name, r.constraint_name;
  END LOOP;
END $$;