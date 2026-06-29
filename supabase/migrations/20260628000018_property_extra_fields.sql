-- ============================================================================
-- IMMOBILIER — BONUS : fiche bien enrichie (champs optionnels). Additif.
-- ============================================================================

BEGIN;

ALTER TABLE public.properties
  ADD COLUMN IF NOT EXISTS year_built     INTEGER,
  ADD COLUMN IF NOT EXISTS floor_number   INTEGER,
  ADD COLUMN IF NOT EXISTS total_floors   INTEGER,
  ADD COLUMN IF NOT EXISTS has_parking    BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS furnished      BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS charges_amount NUMERIC,
  ADD COLUMN IF NOT EXISTS orientation    TEXT;

COMMIT;
