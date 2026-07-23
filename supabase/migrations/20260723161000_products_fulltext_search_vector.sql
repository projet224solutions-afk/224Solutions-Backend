-- ============================================================================
-- RECHERCHE FULL-TEXT PRODUITS — sans plafond structurel
-- ============================================================================
-- Existant (audit 23/07) :
--   - Colonne GÉNÉRÉE `search_text` = f_unaccent(lower(name || ' ' || description))
--   - Index trigram GIN `idx_products_search_text_trgm` (gin_trgm_ops) — UTILISÉ.
--     => la tolérance aux fautes de frappe (« sublimasion » -> « sublimation »)
--        est DÉJÀ couverte, mais uniquement sur name+description.
--
-- Ce qui manque, et que le prompt exige EN PLUS du trigram :
--   - Un `tsvector` full-text (config française) pour un classement par
--     PERTINENCE (ts_rank) et la recherche multi-mots (websearch_to_tsquery),
--     couvrant aussi le SKU et le code-barres.
--
-- Choix : colonne GÉNÉRÉE STORED (comme search_text) plutôt qu'un 12e trigger.
--   - to_tsvector('french'::regconfig, ...) est IMMUTABLE (config littérale).
--   - f_unaccent est IMMUTABLE (déjà utilisée dans la génération de search_text).
--   - On repart des colonnes de BASE (une colonne générée ne peut pas référencer
--     une autre colonne générée en Postgres).
-- ============================================================================

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS search_vector tsvector
  GENERATED ALWAYS AS (
    to_tsvector(
      'french'::regconfig,
      f_unaccent(lower(
        coalesce(name, '')        || ' ' ||
        coalesce(description, '')  || ' ' ||
        coalesce(sku, '')          || ' ' ||
        coalesce(barcode, '')
      ))
    )
  ) STORED;

COMMENT ON COLUMN public.products.search_vector IS
  'Full-text français (pertinence/multi-mots) sur name+description+sku+barcode. Complète le trigram search_text (tolérance aux fautes). Généré STORED, indexé GIN.';

-- Index GIN créé en CONCURRENTLY hors de ce fichier (voir script d'application) :
--   CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_products_search_vector
--     ON public.products USING gin (search_vector);
