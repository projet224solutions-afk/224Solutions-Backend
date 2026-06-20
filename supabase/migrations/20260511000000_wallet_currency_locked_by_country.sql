-- =================================================================
-- MIGRATION: Verrouillage devise wallet selon pays de résidence
-- Date: 2026-05-11
-- Objectif: Chaque wallet reçoit automatiquement la devise du pays
--           de l'utilisateur et cette devise est verrouillée.
-- =================================================================

-- 1. AJOUTER COLONNES currency_locked AU TABLE wallets
ALTER TABLE wallets
  ADD COLUMN IF NOT EXISTS currency_locked BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS currency_locked_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS currency_lock_reason TEXT;

-- 2. FONCTION: Retourner la devise officielle selon code pays (ISO 3166-1 alpha-2)
CREATE OR REPLACE FUNCTION get_currency_for_country(p_country_code TEXT)
RETURNS VARCHAR(3) AS $$
BEGIN
  RETURN CASE UPPER(TRIM(p_country_code))
    -- AFRIQUE DE L'OUEST
    WHEN 'GN' THEN 'GNF'   -- Guinée
    WHEN 'SN' THEN 'XOF'   -- Sénégal
    WHEN 'ML' THEN 'XOF'   -- Mali
    WHEN 'CI' THEN 'XOF'   -- Côte d'Ivoire
    WHEN 'BF' THEN 'XOF'   -- Burkina Faso
    WHEN 'NE' THEN 'XOF'   -- Niger
    WHEN 'TG' THEN 'XOF'   -- Togo
    WHEN 'BJ' THEN 'XOF'   -- Bénin
    WHEN 'GW' THEN 'XOF'   -- Guinée-Bissau
    WHEN 'SL' THEN 'SLL'   -- Sierra Leone
    WHEN 'LR' THEN 'LRD'   -- Liberia
    WHEN 'GM' THEN 'GMD'   -- Gambie
    WHEN 'NG' THEN 'NGN'   -- Nigeria
    WHEN 'GH' THEN 'GHS'   -- Ghana
    WHEN 'MR' THEN 'MRU'   -- Mauritanie
    WHEN 'CV' THEN 'CVE'   -- Cap-Vert
    -- AFRIQUE CENTRALE
    WHEN 'CM' THEN 'XAF'   -- Cameroun
    WHEN 'GA' THEN 'XAF'   -- Gabon
    WHEN 'TD' THEN 'XAF'   -- Tchad
    WHEN 'CF' THEN 'XAF'   -- Centrafrique
    WHEN 'CG' THEN 'XAF'   -- Congo
    WHEN 'GQ' THEN 'XAF'   -- Guinée Équatoriale
    WHEN 'CD' THEN 'CDF'   -- RD Congo
    WHEN 'ST' THEN 'STN'   -- Sao Tomé
    -- AFRIQUE DU NORD
    WHEN 'MA' THEN 'MAD'   -- Maroc
    WHEN 'DZ' THEN 'DZD'   -- Algérie
    WHEN 'TN' THEN 'TND'   -- Tunisie
    WHEN 'EG' THEN 'EGP'   -- Égypte
    WHEN 'LY' THEN 'LYD'   -- Libye
    -- AFRIQUE DE L'EST
    WHEN 'KE' THEN 'KES'   -- Kenya
    WHEN 'TZ' THEN 'TZS'   -- Tanzanie
    WHEN 'UG' THEN 'UGX'   -- Ouganda
    WHEN 'RW' THEN 'RWF'   -- Rwanda
    WHEN 'ET' THEN 'ETB'   -- Éthiopie
    -- AFRIQUE AUSTRALE
    WHEN 'ZA' THEN 'ZAR'   -- Afrique du Sud
    WHEN 'NA' THEN 'NAD'   -- Namibie
    WHEN 'BW' THEN 'BWP'   -- Botswana
    WHEN 'ZM' THEN 'ZMW'   -- Zambie
    WHEN 'MZ' THEN 'MZN'   -- Mozambique
    WHEN 'AO' THEN 'AOA'   -- Angola
    -- OCÉAN INDIEN
    WHEN 'MG' THEN 'MGA'   -- Madagascar
    WHEN 'MU' THEN 'MUR'   -- Maurice
    WHEN 'KM' THEN 'KMF'   -- Comores
    -- EUROPE (ZONE EURO)
    WHEN 'FR' THEN 'EUR'
    WHEN 'DE' THEN 'EUR'
    WHEN 'IT' THEN 'EUR'
    WHEN 'ES' THEN 'EUR'
    WHEN 'PT' THEN 'EUR'
    WHEN 'BE' THEN 'EUR'
    WHEN 'NL' THEN 'EUR'
    WHEN 'AT' THEN 'EUR'
    WHEN 'IE' THEN 'EUR'
    WHEN 'FI' THEN 'EUR'
    WHEN 'GR' THEN 'EUR'
    WHEN 'LU' THEN 'EUR'
    WHEN 'MT' THEN 'EUR'
    WHEN 'CY' THEN 'EUR'
    WHEN 'SK' THEN 'EUR'
    WHEN 'SI' THEN 'EUR'
    WHEN 'EE' THEN 'EUR'
    WHEN 'LV' THEN 'EUR'
    WHEN 'LT' THEN 'EUR'
    WHEN 'HR' THEN 'EUR'
    WHEN 'ME' THEN 'EUR'
    WHEN 'XK' THEN 'EUR'
    -- EUROPE (HORS EURO)
    WHEN 'GB' THEN 'GBP'   -- Royaume-Uni
    WHEN 'CH' THEN 'CHF'   -- Suisse
    WHEN 'NO' THEN 'NOK'   -- Norvège
    WHEN 'SE' THEN 'SEK'   -- Suède
    WHEN 'DK' THEN 'DKK'   -- Danemark
    WHEN 'PL' THEN 'PLN'   -- Pologne
    WHEN 'CZ' THEN 'CZK'   -- Tchéquie
    WHEN 'HU' THEN 'HUF'   -- Hongrie
    WHEN 'RO' THEN 'RON'   -- Roumanie
    WHEN 'RU' THEN 'RUB'   -- Russie
    WHEN 'TR' THEN 'TRY'   -- Turquie
    WHEN 'UA' THEN 'UAH'   -- Ukraine
    -- AMÉRIQUE DU NORD
    WHEN 'US' THEN 'USD'   -- États-Unis
    WHEN 'CA' THEN 'CAD'   -- Canada
    WHEN 'MX' THEN 'MXN'   -- Mexique
    -- AMÉRIQUE DU SUD
    WHEN 'BR' THEN 'BRL'   -- Brésil
    WHEN 'AR' THEN 'ARS'   -- Argentine
    WHEN 'CL' THEN 'CLP'   -- Chili
    WHEN 'CO' THEN 'COP'   -- Colombie
    -- MOYEN-ORIENT
    WHEN 'AE' THEN 'AED'   -- Émirats
    WHEN 'SA' THEN 'SAR'   -- Arabie Saoudite
    WHEN 'QA' THEN 'QAR'   -- Qatar
    WHEN 'KW' THEN 'KWD'   -- Koweït
    -- ASIE
    WHEN 'CN' THEN 'CNY'   -- Chine
    WHEN 'JP' THEN 'JPY'   -- Japon
    WHEN 'KR' THEN 'KRW'   -- Corée du Sud
    WHEN 'IN' THEN 'INR'   -- Inde
    WHEN 'SG' THEN 'SGD'   -- Singapour
    WHEN 'MY' THEN 'MYR'   -- Malaisie
    WHEN 'TH' THEN 'THB'   -- Thaïlande
    -- OCÉANIE
    WHEN 'AU' THEN 'AUD'   -- Australie
    WHEN 'NZ' THEN 'NZD'   -- Nouvelle-Zélande
    ELSE 'GNF'  -- Par défaut: Franc Guinéen
  END;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 3. METTRE À JOUR LE TRIGGER: Créer wallet avec devise du pays
CREATE OR REPLACE FUNCTION trigger_create_wallet()
RETURNS TRIGGER AS $$
DECLARE
  v_country   VARCHAR(3);
  v_currency  VARCHAR(3);
BEGIN
  -- Récupérer le pays détecté ou déclaré du profil
  v_country := COALESCE(
    NEW.detected_country,
    NEW.country,
    'GN'
  );

  -- Déterminer la devise selon le pays
  v_currency := COALESCE(
    NEW.detected_currency,
    get_currency_for_country(v_country),
    'GNF'
  );

  -- Créer le wallet avec la devise du pays, verrouillée
  INSERT INTO wallets (
    user_id,
    balance,
    currency,
    wallet_status,
    currency_locked,
    currency_locked_at,
    currency_lock_reason
  )
  VALUES (
    NEW.id,
    0,
    v_currency,
    'active',
    true,
    NOW(),
    'Devise assignée automatiquement selon le pays de résidence: ' || v_country
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. RECRÉER LE TRIGGER (inchangé, juste s'assurer qu'il est actif)
DROP TRIGGER IF EXISTS trigger_create_wallet_on_profile ON profiles;
CREATE TRIGGER trigger_create_wallet_on_profile
  AFTER INSERT ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION trigger_create_wallet();

-- 5. METTRE À JOUR ensure_user_wallet POUR UTILISER LE PAYS
CREATE OR REPLACE FUNCTION ensure_user_wallet(p_user_id UUID)
RETURNS BIGINT AS $$
DECLARE
  v_wallet_id BIGINT;
  v_country   VARCHAR(3);
  v_currency  VARCHAR(3);
BEGIN
  SELECT id INTO v_wallet_id FROM wallets WHERE user_id = p_user_id;

  IF FOUND THEN
    RETURN v_wallet_id;
  END IF;

  -- Récupérer le pays du profil
  SELECT
    COALESCE(detected_country, country, 'GN'),
    COALESCE(detected_currency, 'GNF')
  INTO v_country, v_currency
  FROM profiles
  WHERE id = p_user_id;

  -- Affiner la devise depuis le pays si nécessaire
  IF v_currency IS NULL OR v_currency = 'GNF' THEN
    v_currency := get_currency_for_country(COALESCE(v_country, 'GN'));
  END IF;

  INSERT INTO wallets (
    user_id,
    balance,
    currency,
    wallet_status,
    currency_locked,
    currency_locked_at,
    currency_lock_reason
  )
  VALUES (
    p_user_id,
    0,
    COALESCE(v_currency, 'GNF'),
    'active',
    true,
    NOW(),
    'Devise assignée automatiquement selon le pays de résidence'
  )
  RETURNING id INTO v_wallet_id;

  RETURN v_wallet_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. RLS: Empêcher les utilisateurs de modifier currency ou currency_locked
-- (Le service role garde tous ses accès via la policy existante)
DROP POLICY IF EXISTS "Users cannot change wallet currency" ON wallets;
CREATE POLICY "Users cannot change wallet currency"
ON wallets FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (
  -- L'utilisateur ne peut pas changer la devise ni déverrouiller
  currency = (SELECT w.currency FROM wallets w WHERE w.user_id = auth.uid())
  AND currency_locked = true
);

-- 7. MIGRATION DES WALLETS EXISTANTS: Appliquer la devise du pays
-- Mettre à jour les wallets qui ont encore 'GNF' comme devise par défaut
-- en vérifiant que le profil indique un autre pays
DO $$
DECLARE
  v_rec       RECORD;
  v_country   VARCHAR(3);
  v_currency  VARCHAR(3);
  v_updated   INTEGER := 0;
  v_skipped   INTEGER := 0;
BEGIN
  FOR v_rec IN
    SELECT w.id AS wallet_id, w.user_id, w.currency, w.currency_locked, p.detected_country, p.country, p.detected_currency
    FROM wallets w
    JOIN profiles p ON p.id = w.user_id
    WHERE w.currency_locked = false OR w.currency_locked IS NULL
  LOOP
    -- Déterminer le pays (uniquement codes ISO 2-3 chars)
    v_country := COALESCE(
      NULLIF(v_rec.detected_country, ''),
      CASE WHEN LENGTH(COALESCE(v_rec.country, '')) BETWEEN 2 AND 3 THEN v_rec.country ELSE NULL END,
      'GN'
    );

    -- Déterminer la devise depuis le pays
    v_currency := COALESCE(
      NULLIF(v_rec.detected_currency, 'GNF'),
      get_currency_for_country(v_country)
    );
    IF v_currency IS NULL THEN
      v_currency := 'GNF';
    END IF;

    -- Mettre à jour seulement si la devise change OU si non verrouillé
    IF v_currency != v_rec.currency OR v_rec.currency_locked IS DISTINCT FROM true THEN
      UPDATE wallets
      SET
        currency           = v_currency,
        currency_locked    = true,
        currency_locked_at = NOW(),
        currency_lock_reason = 'Migration: devise assignée selon pays de résidence (' || v_country || ')',
        updated_at         = NOW()
      WHERE id = v_rec.wallet_id;

      v_updated := v_updated + 1;
    ELSE
      -- Wallet déjà correct mais pas verrouillé → juste verrouiller
      UPDATE wallets
      SET
        currency_locked    = true,
        currency_locked_at = NOW(),
        currency_lock_reason = 'Migration: devise confirmée et verrouillée (' || v_country || ')',
        updated_at         = NOW()
      WHERE id = v_rec.wallet_id;
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;

  RAISE NOTICE '✅ Migration devise wallet: % wallets mis à jour, % wallets confirmés', v_updated, v_skipped;
END $$;

-- 8. INDEX pour les nouvelles colonnes
CREATE INDEX IF NOT EXISTS idx_wallets_currency_locked ON wallets(currency_locked) WHERE currency_locked = true;
