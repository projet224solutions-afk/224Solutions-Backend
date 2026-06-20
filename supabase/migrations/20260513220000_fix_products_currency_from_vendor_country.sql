-- =================================================================
-- MIGRATION: Correction de products.currency depuis le pays vendeur
-- Date: 2026-05-13
--
-- Problème: La migration 20260508100000 a ajouté currency DEFAULT 'GNF',
-- ce qui a rempli TOUS les produits existants avec 'GNF' immédiatement.
-- L'UPDATE WHERE currency IS NULL n'a donc jamais rien mis à jour.
-- Résultat: tous les produits sénégalais, camerounais, etc. ont 'GNF'
-- au lieu de leur devise réelle (XOF, XAF, etc.).
--
-- Solution: Re-calculer currency depuis le pays du vendeur,
--   en gérant à la fois les codes ISO (SN) et les noms complets (Sénégal).
-- =================================================================

UPDATE public.products p
SET currency = CASE
  -- ── Codes ISO alpha-2 ─────────────────────────────────────────
  -- Guinée
  WHEN UPPER(TRIM(v.country)) = 'GN'                                      THEN 'GNF'
  -- Zone XOF (UEMOA)
  WHEN UPPER(TRIM(v.country)) IN ('SN','ML','CI','BF','NE','TG','BJ','GW') THEN 'XOF'
  -- Zone XAF (CEMAC)
  WHEN UPPER(TRIM(v.country)) IN ('CM','GA','TD','CF','CG','GQ')           THEN 'XAF'
  -- Autres Afrique
  WHEN UPPER(TRIM(v.country)) = 'CD' THEN 'CDF'
  WHEN UPPER(TRIM(v.country)) = 'NG' THEN 'NGN'
  WHEN UPPER(TRIM(v.country)) = 'GH' THEN 'GHS'
  WHEN UPPER(TRIM(v.country)) = 'MA' THEN 'MAD'
  WHEN UPPER(TRIM(v.country)) = 'DZ' THEN 'DZD'
  WHEN UPPER(TRIM(v.country)) = 'TN' THEN 'TND'
  WHEN UPPER(TRIM(v.country)) = 'EG' THEN 'EGP'
  WHEN UPPER(TRIM(v.country)) = 'KE' THEN 'KES'
  WHEN UPPER(TRIM(v.country)) = 'TZ' THEN 'TZS'
  WHEN UPPER(TRIM(v.country)) = 'UG' THEN 'UGX'
  WHEN UPPER(TRIM(v.country)) = 'RW' THEN 'RWF'
  WHEN UPPER(TRIM(v.country)) = 'MU' THEN 'MUR'
  -- Europe
  WHEN UPPER(TRIM(v.country)) IN ('FR','DE','BE','IT','ES','PT','NL','AT',
                                    'IE','FI','GR','LU','MT','CY','SK','SI',
                                    'EE','LV','LT','HR','ME','XK')          THEN 'EUR'
  WHEN UPPER(TRIM(v.country)) = 'GB' THEN 'GBP'
  WHEN UPPER(TRIM(v.country)) = 'CH' THEN 'CHF'
  -- Amérique / Asie
  WHEN UPPER(TRIM(v.country)) IN ('US','EC','TL')                          THEN 'USD'
  WHEN UPPER(TRIM(v.country)) = 'CA' THEN 'CAD'
  WHEN UPPER(TRIM(v.country)) = 'JP' THEN 'JPY'
  WHEN UPPER(TRIM(v.country)) = 'CN' THEN 'CNY'
  WHEN UPPER(TRIM(v.country)) = 'IN' THEN 'INR'
  WHEN UPPER(TRIM(v.country)) = 'AE' THEN 'AED'
  WHEN UPPER(TRIM(v.country)) = 'SA' THEN 'SAR'

  -- ── Noms complets (stockés en toutes lettres dans vendors.country) ──
  WHEN LOWER(TRIM(v.country)) IN ('guinée','guinee','guinea')               THEN 'GNF'
  WHEN LOWER(TRIM(v.country)) IN ('sénégal','senegal')                      THEN 'XOF'
  WHEN LOWER(TRIM(v.country)) IN ('mali')                                   THEN 'XOF'
  WHEN LOWER(TRIM(v.country)) IN ('côte d''ivoire','cote d''ivoire',
                                   'ivory coast','côte-d''ivoire')           THEN 'XOF'
  WHEN LOWER(TRIM(v.country)) IN ('burkina faso','burkina')                 THEN 'XOF'
  WHEN LOWER(TRIM(v.country)) IN ('niger')                                  THEN 'XOF'
  WHEN LOWER(TRIM(v.country)) IN ('togo')                                   THEN 'XOF'
  WHEN LOWER(TRIM(v.country)) IN ('bénin','benin')                          THEN 'XOF'
  WHEN LOWER(TRIM(v.country)) IN ('cameroun','cameroon')                    THEN 'XAF'
  WHEN LOWER(TRIM(v.country)) IN ('gabon')                                  THEN 'XAF'
  WHEN LOWER(TRIM(v.country)) IN ('tchad','chad')                           THEN 'XAF'
  WHEN LOWER(TRIM(v.country)) IN ('congo','république du congo',
                                   'congo-brazzaville')                      THEN 'XAF'
  WHEN LOWER(TRIM(v.country)) IN ('rd congo','rdc','congo-kinshasa',
                                   'république démocratique du congo',
                                   'democratic republic of congo')           THEN 'CDF'
  WHEN LOWER(TRIM(v.country)) IN ('nigeria','nigéria')                      THEN 'NGN'
  WHEN LOWER(TRIM(v.country)) IN ('ghana')                                  THEN 'GHS'
  WHEN LOWER(TRIM(v.country)) IN ('maroc','morocco')                        THEN 'MAD'
  WHEN LOWER(TRIM(v.country)) IN ('france')                                 THEN 'EUR'
  WHEN LOWER(TRIM(v.country)) IN ('belgique','belgium')                     THEN 'EUR'
  WHEN LOWER(TRIM(v.country)) IN ('états-unis','etats-unis',
                                   'united states','usa')                    THEN 'USD'
  WHEN LOWER(TRIM(v.country)) IN ('royaume-uni','united kingdom','uk')      THEN 'GBP'
  WHEN LOWER(TRIM(v.country)) IN ('canada')                                 THEN 'CAD'

  -- Pas de correspondance → conserver la valeur actuelle
  ELSE p.currency
END
FROM public.vendors v
WHERE p.vendor_id = v.id
  AND v.country IS NOT NULL
  AND TRIM(v.country) != '';

-- Log du résultat
DO $$
DECLARE
  updated_count INTEGER;
BEGIN
  GET DIAGNOSTICS updated_count = ROW_COUNT;
  RAISE LOG '[fix_products_currency] % produits mis à jour avec la devise correcte du vendeur', updated_count;
END;
$$;
