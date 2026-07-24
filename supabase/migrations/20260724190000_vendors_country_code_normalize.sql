-- ============================================================================
-- Normaliser le pays des vendeurs sur le référentiel ISO-2 `public.countries`
-- ============================================================================
-- P1 : `vendors.country` est un TEXT libre (DEFAULT 'Guinée'), incompatible avec le reste
-- de la plateforme qui utilise `countries.country_code` (ISO-2). On ajoute `country_code`
-- rattaché au référentiel, on backfille depuis le texte existant, et on retire le DEFAULT
-- piégeux (tout nouveau vendeur devenait guinéen en silence).
--
-- `vendors.country` N'EST PAS supprimé (affichage + rollback ; retrait dans une passe ultérieure).
-- Idempotent : IF NOT EXISTS + UPDATE gardé sur country_code IS NULL.
-- `unaccent` est disponible en base (vérifié) → backfill insensible casse/accents.
-- ============================================================================

-- 1. Colonne ISO-2 rattachée au référentiel existant
ALTER TABLE public.vendors
  ADD COLUMN IF NOT EXISTS country_code text REFERENCES public.countries(country_code);

-- 2. Backfill depuis le texte libre existant (insensible casse/accents, égalité EXACTE →
--    « Guinée » ne matche QUE GN, jamais « Guinée-Bissau »/« Guinée équatoriale »)
UPDATE public.vendors v
SET country_code = c.country_code
FROM public.countries c
WHERE v.country_code IS NULL
  AND v.country IS NOT NULL
  AND extensions.unaccent(lower(trim(v.country))) = extensions.unaccent(lower(c.country_name));

-- 3. Filet : les vendeurs restants sans correspondance -> GN (historique, defaut 'Guinée')
UPDATE public.vendors
SET country_code = 'GN'
WHERE country_code IS NULL;

-- 4. Index de filtrage
CREATE INDEX IF NOT EXISTS idx_vendors_country_code ON public.vendors(country_code);
CREATE INDEX IF NOT EXISTS idx_vendors_city_lower   ON public.vendors(lower(city));

-- 5. Retirer le DEFAULT piégeux (tout vendeur devenait guinéen en silence)
ALTER TABLE public.vendors ALTER COLUMN country DROP DEFAULT;
