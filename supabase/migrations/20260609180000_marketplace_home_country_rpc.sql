-- ============================================================================
-- RPC ATOMIQUE — décision « pays maison » du marketplace
-- ----------------------------------------------------------------------------
-- Encapsule TOUTE la décision pays dans UNE seule fonction (snapshot cohérent),
-- comme les opérations wallet : résolution du pays détecté (nom ou code ISO-2),
-- comptage des produits affichables (vendeur en ligne/hybride, actif) et seuil.
-- Appelée par le backend Node.js (/api/v2/marketplace/home-country). Lecture seule,
-- SECURITY DEFINER (contourne la RLS pour un comptage fiable), rejouable.
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

  -- Comptage atomique des produits affichables du pays maison (même snapshot)
  IF v_home IS NOT NULL THEN
    SELECT COUNT(*) INTO v_count
    FROM public.products p
    JOIN public.vendors v ON v.id = p.vendor_id
    WHERE p.is_active = true
      AND v.business_type IN ('online', 'hybrid')
      AND lower(btrim(regexp_replace(v.country, '\s+', ' ', 'g'))) = lower(v_home);
  END IF;

  v_qualifies := (v_home IS NOT NULL) AND (v_count >= COALESCE(p_threshold, 30));

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

GRANT EXECUTE ON FUNCTION public.get_marketplace_home_country(text, int)
  TO anon, authenticated, service_role;

SELECT 'get_marketplace_home_country créée (décision pays atomique en 1 appel).' AS status;
