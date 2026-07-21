-- ============================================================================
-- Mapping pays éditable PDG (GAP B) : la LANGUE par défaut d'un pays n'était pas en base
-- (embarquée dans geo.routes COUNTRY_LANG) → non éditable sans redéploiement. On ajoute
-- countries.default_language + backfill, pour que le PDG puisse gérer pays→devise→langue→indicatif
-- depuis l'interface (devise/indicatif/actif étaient déjà en table).
--
-- ✅ APPLIQUÉE EN PROD le 2026-07-21 (API Management). Idempotente.
-- ============================================================================

ALTER TABLE public.countries ADD COLUMN IF NOT EXISTS default_language text;

UPDATE public.countries SET default_language = CASE upper(country_code)
  -- francophone
  WHEN 'GN' THEN 'fr' WHEN 'SN' THEN 'fr' WHEN 'ML' THEN 'fr' WHEN 'CI' THEN 'fr'
  WHEN 'BF' THEN 'fr' WHEN 'NE' THEN 'fr' WHEN 'TG' THEN 'fr' WHEN 'BJ' THEN 'fr'
  WHEN 'MR' THEN 'fr' WHEN 'CM' THEN 'fr' WHEN 'CD' THEN 'fr' WHEN 'CG' THEN 'fr'
  WHEN 'GA' THEN 'fr' WHEN 'TD' THEN 'fr' WHEN 'CF' THEN 'fr' WHEN 'DJ' THEN 'fr'
  WHEN 'KM' THEN 'fr' WHEN 'MG' THEN 'fr' WHEN 'GQ' THEN 'fr' WHEN 'FR' THEN 'fr'
  WHEN 'BE' THEN 'fr' WHEN 'LU' THEN 'fr' WHEN 'CH' THEN 'fr'
  -- anglophone
  WHEN 'NG' THEN 'en' WHEN 'GH' THEN 'en' WHEN 'KE' THEN 'en' WHEN 'UG' THEN 'en'
  WHEN 'TZ' THEN 'en' WHEN 'ZA' THEN 'en' WHEN 'ZM' THEN 'en' WHEN 'ZW' THEN 'en'
  WHEN 'LR' THEN 'en' WHEN 'SL' THEN 'en' WHEN 'GM' THEN 'en' WHEN 'BW' THEN 'en'
  WHEN 'RW' THEN 'en' WHEN 'MW' THEN 'en' WHEN 'NA' THEN 'en' WHEN 'US' THEN 'en'
  WHEN 'GB' THEN 'en' WHEN 'IE' THEN 'en' WHEN 'CA' THEN 'en' WHEN 'AU' THEN 'en'
  -- lusophone
  WHEN 'GW' THEN 'pt' WHEN 'AO' THEN 'pt' WHEN 'MZ' THEN 'pt' WHEN 'CV' THEN 'pt'
  WHEN 'ST' THEN 'pt' WHEN 'PT' THEN 'pt' WHEN 'BR' THEN 'pt'
  -- arabophone
  WHEN 'MA' THEN 'ar' WHEN 'DZ' THEN 'ar' WHEN 'TN' THEN 'ar' WHEN 'LY' THEN 'ar'
  WHEN 'EG' THEN 'ar' WHEN 'SD' THEN 'ar' WHEN 'SA' THEN 'ar' WHEN 'AE' THEN 'ar'
  WHEN 'QA' THEN 'ar' WHEN 'KW' THEN 'ar' WHEN 'BH' THEN 'ar' WHEN 'OM' THEN 'ar'
  WHEN 'JO' THEN 'ar' WHEN 'LB' THEN 'ar' WHEN 'IQ' THEN 'ar' WHEN 'YE' THEN 'ar'
  WHEN 'SY' THEN 'ar'
  -- autres
  WHEN 'DE' THEN 'de' WHEN 'ES' THEN 'es' WHEN 'IT' THEN 'it' WHEN 'NL' THEN 'nl'
  WHEN 'RU' THEN 'ru' WHEN 'TR' THEN 'tr' WHEN 'CN' THEN 'zh'
  ELSE COALESCE(default_language, 'fr')
END
WHERE default_language IS NULL;

SELECT 'countries.default_language ajouté + backfilé (mapping pays→langue éditable PDG).' AS status;
