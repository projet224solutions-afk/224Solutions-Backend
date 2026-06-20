-- ============================================================================
-- Recherche marketplace INSENSIBLE AUX ACCENTS (et à la casse)
-- ----------------------------------------------------------------------------
-- Problème : `ilike` ignore la casse mais PAS les accents → « electro » ne trouvait
-- pas « Électronique ». On ajoute des colonnes GÉNÉRÉES `search_text` (unaccentées +
-- minuscules) sur products/digital_products/professional_services et `search_name`
-- sur categories, avec index trigram (GIN) pour des `%terme%` performants.
-- Le front retire les accents du terme côté client et cherche sur ces colonnes.
--
-- ⚠️ Convention de CE projet : les extensions vivent dans le schéma `extensions`
-- (cf. extensions.gen_random_bytes). On qualifie donc `extensions.` partout.
-- Non destructif, rejouable. (Tables petites → ADD COLUMN GENERATED instantané.)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

-- Wrapper IMMUTABLE de unaccent (requis pour colonnes générées / index).
-- Dictionnaire et fonction qualifiés `extensions.` (schéma des extensions Supabase).
CREATE OR REPLACE FUNCTION public.f_unaccent(text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
STRICT
AS $$ SELECT extensions.unaccent('extensions.unaccent', $1) $$;

-- Produits : nom + description
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS search_text text
  GENERATED ALWAYS AS (
    public.f_unaccent(lower(coalesce(name, '') || ' ' || coalesce(description, '')))
  ) STORED;
CREATE INDEX IF NOT EXISTS idx_products_search_text_trgm
  ON public.products USING gin (search_text extensions.gin_trgm_ops);

-- Produits numériques : titre + description
ALTER TABLE public.digital_products
  ADD COLUMN IF NOT EXISTS search_text text
  GENERATED ALWAYS AS (
    public.f_unaccent(lower(coalesce(title, '') || ' ' || coalesce(description, '')))
  ) STORED;
CREATE INDEX IF NOT EXISTS idx_digital_products_search_text_trgm
  ON public.digital_products USING gin (search_text extensions.gin_trgm_ops);

-- Services pro : nom commercial + description
ALTER TABLE public.professional_services
  ADD COLUMN IF NOT EXISTS search_text text
  GENERATED ALWAYS AS (
    public.f_unaccent(lower(coalesce(business_name, '') || ' ' || coalesce(description, '')))
  ) STORED;
CREATE INDEX IF NOT EXISTS idx_prof_services_search_text_trgm
  ON public.professional_services USING gin (search_text extensions.gin_trgm_ops);

-- Catégories : nom (pour l'élargissement de la recherche produits par catégorie)
ALTER TABLE public.categories
  ADD COLUMN IF NOT EXISTS search_name text
  GENERATED ALWAYS AS (public.f_unaccent(lower(coalesce(name, '')))) STORED;
CREATE INDEX IF NOT EXISTS idx_categories_search_name_trgm
  ON public.categories USING gin (search_name extensions.gin_trgm_ops);

SELECT 'Recherche insensible aux accents installée (search_text / search_name + index trigram).' AS status;
