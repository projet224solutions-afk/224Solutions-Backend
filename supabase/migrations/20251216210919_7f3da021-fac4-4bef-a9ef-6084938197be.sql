-- Retrocompatible alias: some legacy functions call gen_random_bytes() without schema
-- In Supabase, pgcrypto is commonly installed in schema `extensions`, so we expose a stable shim in `public`.
CREATE OR REPLACE FUNCTION public.gen_random_bytes(p_size integer)
RETURNS bytea
LANGUAGE sql
SECURITY DEFINER
SET search_path = extensions
AS $$
  SELECT extensions.gen_random_bytes(p_size);
$$;

-- Optional: ensure callable by Postgres functions regardless of caller role
GRANT EXECUTE ON FUNCTION public.gen_random_bytes(integer) TO public, anon, authenticated;