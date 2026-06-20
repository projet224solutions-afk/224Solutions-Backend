-- =================================================================
-- MIGRATION: Correction système de verrouillage devise
-- Date: 2026-05-13
-- Objectif: Appliquer toutes les colonnes manquantes (currency_locked,
--           profile_completed) et corriger complete_country_setup
--           pour respecter les verrous posés par le PDG.
-- =================================================================

-- ─────────────────────────────────────────────────────────────────
-- 1. COLONNES MANQUANTES — wallets
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE wallets
  ADD COLUMN IF NOT EXISTS currency_locked      BOOLEAN   DEFAULT false,
  ADD COLUMN IF NOT EXISTS currency_locked_at   TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS currency_lock_reason TEXT;

-- ─────────────────────────────────────────────────────────────────
-- 2. COLONNES MANQUANTES — vendors
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE vendors
  ADD COLUMN IF NOT EXISTS shop_currency       VARCHAR(3),
  ADD COLUMN IF NOT EXISTS currency_locked     BOOLEAN DEFAULT false,
  ADD COLUMN IF NOT EXISTS seller_country_code VARCHAR(2);

-- Initialiser shop_currency depuis country existant pour les vendeurs sans devise
UPDATE vendors
SET
  seller_country_code = CASE
    WHEN LENGTH(COALESCE(country,'')) = 2 THEN UPPER(country)
    WHEN LOWER(country) = 'guinée'               THEN 'GN'
    WHEN LOWER(country) LIKE 'sénégal%'          THEN 'SN'
    WHEN LOWER(country) LIKE 'côte%'             THEN 'CI'
    WHEN LOWER(country) = 'mali'                 THEN 'ML'
    WHEN LOWER(country) = 'cameroun'             THEN 'CM'
    WHEN LOWER(country) = 'france'               THEN 'FR'
    WHEN LOWER(country) = 'nigeria'              THEN 'NG'
    WHEN LOWER(country) = 'ghana'                THEN 'GH'
    WHEN LOWER(country) = 'maroc'                THEN 'MA'
    WHEN LOWER(country) IN ('usa','états-unis','etats-unis') THEN 'US'
    WHEN LOWER(country) = 'canada'               THEN 'CA'
    WHEN LOWER(country) IN ('uk','royaume-uni')  THEN 'GB'
    ELSE NULL
  END,
  shop_currency = COALESCE(shop_currency, 'GNF')
WHERE shop_currency IS NULL;

-- ─────────────────────────────────────────────────────────────────
-- 3. COLONNES MANQUANTES — profiles
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS profile_completed BOOLEAN DEFAULT false;

-- Marquer les profils existants avec pays défini comme complétés
UPDATE profiles
SET profile_completed = true
WHERE profile_completed IS NOT TRUE
  AND (
    (detected_country IS NOT NULL AND detected_country != '')
    OR (country IS NOT NULL AND country != '' AND LENGTH(country) <= 3)
  );

-- ─────────────────────────────────────────────────────────────────
-- 4. VERROUILLER LES WALLETS EXISTANTS non encore verrouillés
-- ─────────────────────────────────────────────────────────────────
UPDATE wallets
SET
  currency_locked      = true,
  currency_locked_at   = NOW(),
  currency_lock_reason = COALESCE(
    currency_lock_reason,
    'Verrou appliqué lors de la migration 2026-05-13'
  )
WHERE currency_locked IS NOT TRUE;

-- ─────────────────────────────────────────────────────────────────
-- 5. RLS: Empêcher les utilisateurs de modifier currency ou le verrou
--    (service_role / admin contourne toujours le RLS)
-- ─────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users cannot change wallet currency" ON wallets;
CREATE POLICY "Users cannot change wallet currency"
ON wallets FOR UPDATE
USING (auth.uid() = user_id)
WITH CHECK (
  currency       = (SELECT w.currency       FROM wallets w WHERE w.user_id = auth.uid() LIMIT 1)
  AND currency_locked = true
);

-- ─────────────────────────────────────────────────────────────────
-- 6. RECRÉER complete_country_setup
--    Vérifie le verrou PDG avant de changer la devise
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION complete_country_setup(
    p_country_code TEXT,
    p_country_name TEXT,
    p_currency     TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id        UUID;
    v_wallet_balance NUMERIC := 0;
    v_wallet_id      BIGINT;
    v_needs_admin    BOOLEAN := false;
    v_is_pdg_locked  BOOLEAN := false;
    v_lock_reason    TEXT;
    card_number      TEXT;
    card_cvv         TEXT;
    v_full_name      TEXT;
BEGIN
    -- Vérifier l'authentification
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Non authentifié');
    END IF;

    -- Valider les paramètres
    IF p_country_code IS NULL OR LENGTH(TRIM(p_country_code)) != 2 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Code pays invalide (2 caractères requis)');
    END IF;
    IF p_currency IS NULL OR LENGTH(TRIM(p_currency)) != 3 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Code devise invalide (3 caractères requis)');
    END IF;

    -- Mettre à jour le profil avec le pays sélectionné
    UPDATE profiles SET
        detected_country   = UPPER(TRIM(p_country_code)),
        country            = p_country_name,
        detected_currency  = UPPER(TRIM(p_currency)),
        profile_completed  = true,
        updated_at         = NOW()
    WHERE id = v_user_id;

    -- Vérifier si un wallet existe
    SELECT id, balance, currency_locked, currency_lock_reason
    INTO v_wallet_id, v_wallet_balance, v_is_pdg_locked, v_lock_reason
    FROM wallets
    WHERE user_id = v_user_id
    ORDER BY updated_at DESC
    LIMIT 1;

    IF v_wallet_id IS NOT NULL THEN

        -- Si le wallet est verrouillé par le PDG → ne pas changer la devise
        IF v_is_pdg_locked = true
           AND v_lock_reason IS NOT NULL
           AND v_lock_reason LIKE '%PDG%'
        THEN
            RETURN jsonb_build_object(
                'success',          true,
                'profile_updated',  true,
                'currency_unchanged', true,
                'message',          'Devise wallet gérée par le PDG — profil mis à jour uniquement'
            );
        END IF;

        IF v_wallet_balance = 0 THEN
            -- Solde nul → mise à jour sûre de la devise
            UPDATE wallets SET
                currency             = UPPER(TRIM(p_currency)),
                currency_locked      = true,
                currency_locked_at   = NOW(),
                currency_lock_reason = 'Devise assignée lors de la sélection du pays: '
                                        || UPPER(TRIM(p_country_code)),
                wallet_status        = 'active',
                updated_at           = NOW()
            WHERE id = v_wallet_id;
        ELSE
            -- Solde non nul → ne pas changer, signaler pour vérification admin
            v_needs_admin := true;
        END IF;

    ELSE
        -- Aucun wallet → créer avec la bonne devise verrouillée
        INSERT INTO wallets (
            user_id, balance, currency, wallet_status,
            currency_locked, currency_locked_at, currency_lock_reason
        )
        VALUES (
            v_user_id, 0, UPPER(TRIM(p_currency)), 'active',
            true, NOW(),
            'Devise assignée lors de la sélection du pays: ' || UPPER(TRIM(p_country_code))
        )
        RETURNING id INTO v_wallet_id;

        -- Créer la carte virtuelle associée
        SELECT TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, ''))
        INTO v_full_name FROM profiles WHERE id = v_user_id;
        IF v_full_name IS NULL OR TRIM(v_full_name) = '' THEN
            SELECT SPLIT_PART(email, '@', 1) INTO v_full_name FROM auth.users WHERE id = v_user_id;
        END IF;

        card_number := generate_virtual_card_number();
        card_cvv    := generate_card_cvv();

        INSERT INTO public.virtual_cards (
            user_id, wallet_id, card_number, card_holder_name,
            expiry_month, expiry_year, cvv, card_type, card_status,
            daily_limit, monthly_limit
        )
        VALUES (
            v_user_id, v_wallet_id, card_number, v_full_name,
            LPAD(EXTRACT(MONTH FROM NOW())::TEXT, 2, '0'),
            EXTRACT(YEAR FROM (NOW() + INTERVAL '3 years'))::TEXT,
            card_cvv, 'virtual', 'active', 500000.00, 10000000.00
        )
        ON CONFLICT (user_id) DO UPDATE SET
            wallet_id   = EXCLUDED.wallet_id,
            card_status = 'active',
            updated_at  = NOW();
    END IF;

    RETURN jsonb_build_object(
        'success',            true,
        'currency',           UPPER(TRIM(p_currency)),
        'country_code',       UPPER(TRIM(p_country_code)),
        'wallet_id',          v_wallet_id,
        'needs_admin_review', v_needs_admin
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Autoriser les utilisateurs authentifiés à appeler cette fonction
GRANT EXECUTE ON FUNCTION complete_country_setup(TEXT, TEXT, TEXT) TO authenticated;

-- ─────────────────────────────────────────────────────────────────
-- 7. INDEX
-- ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_wallets_currency_locked
  ON wallets(currency_locked) WHERE currency_locked = true;
CREATE INDEX IF NOT EXISTS idx_profiles_profile_completed
  ON profiles(profile_completed) WHERE profile_completed = false;
