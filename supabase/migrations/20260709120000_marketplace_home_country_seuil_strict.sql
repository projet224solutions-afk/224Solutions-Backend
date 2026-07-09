-- ============================================================================
-- CORRECTIF — RPC « pays maison » : seuil STRICT (>) + comptage MULTI-VARIANTES
-- ----------------------------------------------------------------------------
-- Remplace get_marketplace_home_country (créée dans 20260609180000) pour aligner
-- la RPC (chemin PRINCIPAL) sur la règle produit décidée par le PDG :
--   • AU PLUS 30 produits (≤ 30)  → l'utilisateur démarre sur MONDIAL
--   • DÉPASSE 30 produits (≥ 31)  → l'utilisateur démarre sur PRODUITS (son pays)
-- Deux corrections vs la version initiale :
--   1) Seuil STRICT : v_count > p_threshold  (au lieu de >=, qui basculait à 30 pile).
--   2) Comptage MULTI-VARIANTES : vendors.country peut stocker le NOM ('France')
--      OU le CODE ISO ('FR') → on compte les produits des DEUX écritures du pays.
-- CREATE OR REPLACE = non destructif, rejouable, réponse JSON INCHANGÉE, mêmes grants.
-- Lecture seule, SECURITY DEFINER (comptage fiable hors RLS).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_marketplace_home_country(
  p_detected  text DEFAULT '',
  p_threshold int  DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_detected      text := COALESCE(btrim(p_detected), '');
  v_norm          text;
  v_name_code     text;
  v_home          text;
  v_alt           text;
  v_variants      text[];
  v_count         int := 0;
  v_countries     text[];
  v_qualifies     boolean := false;
BEGIN
  -- Normalisation (minuscules, espaces compactés)
  v_norm := lower(btrim(regexp_replace(v_detected, '\s+', ' ', 'g')));

  -- Pays « chips » = vendeurs visibles (actifs, non strictement physiques)
  SELECT COALESCE(array_agg(c ORDER BY c), ARRAY[]::text[]) INTO v_countries
  FROM (
    SELECT DISTINCT btrim(regexp_replace(country, '\s+', ' ', 'g')) AS c
    FROM public.vendors
    WHERE is_active = true
      AND country IS NOT NULL
      AND btrim(country) <> ''
      AND (business_type IS NULL OR business_type <> 'physical')
  ) t
  WHERE c <> '';

  -- Résolution du pays détecté
  IF v_norm <> '' THEN
    -- 1) correspondance directe par nom
    SELECT c INTO v_home FROM unnest(v_countries) AS c WHERE lower(c) = v_norm LIMIT 1;

    -- 2) sinon code ISO-2 → nom FR, puis correspondance
    IF v_home IS NULL AND length(v_detected) = 2 THEN
      v_name_code := CASE upper(v_detected)
        WHEN 'GN' THEN 'Guinée'        WHEN 'SN' THEN 'Sénégal'       WHEN 'ML' THEN 'Mali'
        WHEN 'CI' THEN 'Côte d''Ivoire' WHEN 'BF' THEN 'Burkina Faso'  WHEN 'NE' THEN 'Niger'
        WHEN 'TG' THEN 'Togo'          WHEN 'BJ' THEN 'Bénin'         WHEN 'GW' THEN 'Guinée-Bissau'
        WHEN 'SL' THEN 'Sierra Leone'  WHEN 'LR' THEN 'Liberia'       WHEN 'GM' THEN 'Gambie'
        WHEN 'NG' THEN 'Nigeria'       WHEN 'GH' THEN 'Ghana'         WHEN 'CM' THEN 'Cameroun'
        WHEN 'GA' THEN 'Gabon'         WHEN 'TD' THEN 'Tchad'         WHEN 'CG' THEN 'Congo'
        WHEN 'CD' THEN 'RD Congo'      WHEN 'MA' THEN 'Maroc'         WHEN 'TN' THEN 'Tunisie'
        WHEN 'DZ' THEN 'Algérie'       WHEN 'EG' THEN 'Égypte'        WHEN 'KE' THEN 'Kenya'
        WHEN 'TZ' THEN 'Tanzanie'      WHEN 'UG' THEN 'Ouganda'       WHEN 'RW' THEN 'Rwanda'
        WHEN 'ET' THEN 'Éthiopie'      WHEN 'ZA' THEN 'Afrique du Sud' WHEN 'FR' THEN 'France'
        WHEN 'BE' THEN 'Belgique'      WHEN 'CH' THEN 'Suisse'        WHEN 'CA' THEN 'Canada'
        WHEN 'US' THEN 'États-Unis'    WHEN 'GB' THEN 'Royaume-Uni'   WHEN 'CN' THEN 'Chine'
        WHEN 'JP' THEN 'Japon'         WHEN 'IN' THEN 'Inde'          WHEN 'BR' THEN 'Brésil'
        WHEN 'TR' THEN 'Turquie'       ELSE NULL END;

      IF v_name_code IS NOT NULL THEN
        SELECT c INTO v_home FROM unnest(v_countries) AS c
        WHERE lower(c) = lower(v_name_code) LIMIT 1;
      END IF;
    END IF;
  END IF;

  -- Comptage atomique des produits affichables du pays maison (même snapshot).
  -- MULTI-VARIANTES : on matche le NOM résolu ET son CODE ISO-2 (les deux sens),
  -- car vendors.country peut stocker l'un ou l'autre.
  IF v_home IS NOT NULL THEN
    v_variants := ARRAY[ lower(btrim(regexp_replace(v_home, '\s+', ' ', 'g'))) ];

    IF length(btrim(v_home)) = 2 THEN
      -- v_home est un CODE ISO → ajouter le NOM correspondant
      v_alt := CASE upper(btrim(v_home))
        WHEN 'GN' THEN 'Guinée'        WHEN 'SN' THEN 'Sénégal'       WHEN 'ML' THEN 'Mali'
        WHEN 'CI' THEN 'Côte d''Ivoire' WHEN 'BF' THEN 'Burkina Faso'  WHEN 'NE' THEN 'Niger'
        WHEN 'TG' THEN 'Togo'          WHEN 'BJ' THEN 'Bénin'         WHEN 'GW' THEN 'Guinée-Bissau'
        WHEN 'SL' THEN 'Sierra Leone'  WHEN 'LR' THEN 'Liberia'       WHEN 'GM' THEN 'Gambie'
        WHEN 'NG' THEN 'Nigeria'       WHEN 'GH' THEN 'Ghana'         WHEN 'CM' THEN 'Cameroun'
        WHEN 'GA' THEN 'Gabon'         WHEN 'TD' THEN 'Tchad'         WHEN 'CG' THEN 'Congo'
        WHEN 'CD' THEN 'RD Congo'      WHEN 'MA' THEN 'Maroc'         WHEN 'TN' THEN 'Tunisie'
        WHEN 'DZ' THEN 'Algérie'       WHEN 'EG' THEN 'Égypte'        WHEN 'KE' THEN 'Kenya'
        WHEN 'TZ' THEN 'Tanzanie'      WHEN 'UG' THEN 'Ouganda'       WHEN 'RW' THEN 'Rwanda'
        WHEN 'ET' THEN 'Éthiopie'      WHEN 'ZA' THEN 'Afrique du Sud' WHEN 'FR' THEN 'France'
        WHEN 'BE' THEN 'Belgique'      WHEN 'CH' THEN 'Suisse'        WHEN 'CA' THEN 'Canada'
        WHEN 'US' THEN 'États-Unis'    WHEN 'GB' THEN 'Royaume-Uni'   WHEN 'CN' THEN 'Chine'
        WHEN 'JP' THEN 'Japon'         WHEN 'IN' THEN 'Inde'          WHEN 'BR' THEN 'Brésil'
        WHEN 'TR' THEN 'Turquie'       ELSE NULL END;
    ELSE
      -- v_home est un NOM → ajouter le CODE ISO-2 correspondant
      v_alt := CASE lower(btrim(regexp_replace(v_home, '\s+', ' ', 'g')))
        WHEN 'guinée' THEN 'GN'          WHEN 'sénégal' THEN 'SN'        WHEN 'mali' THEN 'ML'
        WHEN 'côte d''ivoire' THEN 'CI'  WHEN 'burkina faso' THEN 'BF'   WHEN 'niger' THEN 'NE'
        WHEN 'togo' THEN 'TG'            WHEN 'bénin' THEN 'BJ'          WHEN 'guinée-bissau' THEN 'GW'
        WHEN 'sierra leone' THEN 'SL'    WHEN 'liberia' THEN 'LR'        WHEN 'gambie' THEN 'GM'
        WHEN 'nigeria' THEN 'NG'         WHEN 'ghana' THEN 'GH'          WHEN 'cameroun' THEN 'CM'
        WHEN 'gabon' THEN 'GA'           WHEN 'tchad' THEN 'TD'          WHEN 'congo' THEN 'CG'
        WHEN 'rd congo' THEN 'CD'        WHEN 'maroc' THEN 'MA'          WHEN 'tunisie' THEN 'TN'
        WHEN 'algérie' THEN 'DZ'         WHEN 'égypte' THEN 'EG'         WHEN 'kenya' THEN 'KE'
        WHEN 'tanzanie' THEN 'TZ'        WHEN 'ouganda' THEN 'UG'        WHEN 'rwanda' THEN 'RW'
        WHEN 'éthiopie' THEN 'ET'        WHEN 'afrique du sud' THEN 'ZA' WHEN 'france' THEN 'FR'
        WHEN 'belgique' THEN 'BE'        WHEN 'suisse' THEN 'CH'         WHEN 'canada' THEN 'CA'
        WHEN 'états-unis' THEN 'US'      WHEN 'royaume-uni' THEN 'GB'    WHEN 'chine' THEN 'CN'
        WHEN 'japon' THEN 'JP'           WHEN 'inde' THEN 'IN'           WHEN 'brésil' THEN 'BR'
        WHEN 'turquie' THEN 'TR'         ELSE NULL END;
    END IF;

    IF v_alt IS NOT NULL AND lower(btrim(v_alt)) <> ALL (v_variants) THEN
      v_variants := v_variants || lower(btrim(v_alt));
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM public.products p
    JOIN public.vendors v ON v.id = p.vendor_id
    WHERE p.is_active = true
      AND v.business_type IN ('online', 'hybrid')
      AND lower(btrim(regexp_replace(v.country, '\s+', ' ', 'g'))) = ANY (v_variants);
  END IF;

  -- SEUIL STRICT (règle PDG) : ≤ threshold → Mondial ; > threshold → Produits.
  v_qualifies := (v_home IS NOT NULL) AND (v_count > COALESCE(p_threshold, 30));

  RETURN jsonb_build_object(
    'success',      true,
    'homeCountry',  v_home,                         -- NULL si non résolu
    'qualifies',    v_qualifies,
    'productCount', v_count,
    'threshold',    COALESCE(p_threshold, 30),
    'countries',    to_jsonb(v_countries)
  );
END;
$$;

-- Grants inchangés (endpoint marketplace PUBLIC, décision lecture seule).
GRANT EXECUTE ON FUNCTION public.get_marketplace_home_country(text, int)
  TO anon, authenticated, service_role;

SELECT 'get_marketplace_home_country MAJ — seuil strict (>) + comptage multi-variantes.' AS status;
