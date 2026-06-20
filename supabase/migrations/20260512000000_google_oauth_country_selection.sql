-- =================================================================
-- MIGRATION: Sélection obligatoire du pays pour les utilisateurs Google OAuth
-- Date: 2026-05-12
-- Objectif: Forcer la sélection du pays avant la création du wallet
--           pour les utilisateurs s'inscrivant via Google.
-- =================================================================

-- 1. AJOUTER COLONNE profile_completed À LA TABLE profiles
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS profile_completed BOOLEAN DEFAULT false;

-- 2. MARQUER LES PROFILS EXISTANTS AVEC PAYS COMME COMPLÉTÉS
UPDATE profiles
SET profile_completed = true
WHERE (detected_country IS NOT NULL AND detected_country != '')
   OR (country IS NOT NULL AND country != '' AND LENGTH(country) <= 3);

-- 3. INDEX pour les recherches sur profile_completed
CREATE INDEX IF NOT EXISTS idx_profiles_profile_completed
  ON profiles(profile_completed) WHERE profile_completed = false;

-- 4. MODIFIER handle_complete_user_setup POUR NE PAS CRÉER LE WALLET
--    Le wallet sera créé APRÈS la sélection du pays via complete_country_setup()
CREATE OR REPLACE FUNCTION handle_complete_user_setup()
RETURNS TRIGGER AS $$
DECLARE
    user_custom_id TEXT;
    card_number    TEXT;
    card_cvv       TEXT;
    card_expiry_month TEXT;
    card_expiry_year  TEXT;
    user_full_name    TEXT;
    v_wallet_id       BIGINT;
BEGIN
    -- Générer l'ID utilisateur unique
    user_custom_id := generate_user_custom_id();

    -- Créer le profil utilisateur
    INSERT INTO public.profiles (
        id, email, first_name, last_name, role
    )
    VALUES (
        NEW.id,
        NEW.email,
        NEW.raw_user_meta_data ->> 'first_name',
        NEW.raw_user_meta_data ->> 'last_name',
        COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client')
    )
    ON CONFLICT (id) DO UPDATE SET
        email      = EXCLUDED.email,
        first_name = EXCLUDED.first_name,
        last_name  = EXCLUDED.last_name,
        role       = EXCLUDED.role;

    -- Créer l'ID utilisateur
    INSERT INTO public.user_ids (user_id, custom_id)
    VALUES (NEW.id, user_custom_id)
    ON CONFLICT (user_id) DO UPDATE SET custom_id = EXCLUDED.custom_id;

    -- NE PAS créer le wallet ici — il sera créé via complete_country_setup()
    -- après que l'utilisateur ait sélectionné son pays de résidence.
    -- Le trigger trigger_create_wallet_on_profile gère les non-OAuth users.

    -- Construire le nom complet pour la carte
    user_full_name := TRIM(
        COALESCE(NEW.raw_user_meta_data ->> 'first_name', '') || ' ' ||
        COALESCE(NEW.raw_user_meta_data ->> 'last_name', '')
    );
    IF user_full_name = '' OR user_full_name IS NULL THEN
        user_full_name := SPLIT_PART(NEW.email, '@', 1);
    END IF;

    -- Récupérer (ou attendre) le wallet_id pour la carte virtuelle
    -- La carte virtuelle sera créée après la création du wallet
    SELECT id INTO v_wallet_id FROM public.wallets WHERE user_id = NEW.id;

    IF v_wallet_id IS NOT NULL THEN
        card_number := generate_virtual_card_number();
        card_cvv    := generate_card_cvv();
        card_expiry_month := LPAD(EXTRACT(MONTH FROM NOW())::TEXT, 2, '0');
        card_expiry_year  := EXTRACT(YEAR FROM (NOW() + INTERVAL '3 years'))::TEXT;

        INSERT INTO public.virtual_cards (
            user_id, wallet_id, card_number, card_holder_name,
            expiry_month, expiry_year, cvv, card_type, card_status,
            daily_limit, monthly_limit
        )
        VALUES (
            NEW.id, v_wallet_id, card_number, user_full_name,
            card_expiry_month, card_expiry_year, card_cvv,
            'virtual', 'active', 500000.00, 10000000.00
        )
        ON CONFLICT (user_id) DO UPDATE SET
            card_status = 'active',
            updated_at  = NOW();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. MODIFIER trigger_create_wallet POUR GÉRER L'ABSENCE DE PAYS
--    Si detected_country EST NULL (cas OAuth Google) → ne pas créer wallet
--    Si detected_country est défini → créer wallet avec devise correcte
CREATE OR REPLACE FUNCTION trigger_create_wallet()
RETURNS TRIGGER AS $$
DECLARE
    v_country  VARCHAR(3);
    v_currency VARCHAR(3);
BEGIN
    -- Si aucun pays connu → le wallet sera créé via complete_country_setup()
    IF NEW.detected_country IS NULL OR NEW.detected_country = '' THEN
        -- Vérifier si c'est un utilisateur email (non-OAuth) qui a rempli "country"
        IF NEW.country IS NULL OR NEW.country = '' OR LENGTH(NEW.country) > 3 THEN
            -- Pas de pays du tout → ne pas créer le wallet maintenant
            RETURN NEW;
        END IF;
    END IF;

    -- Récupérer le pays (detected_country prioritaire)
    v_country := COALESCE(
        NULLIF(NEW.detected_country, ''),
        CASE WHEN LENGTH(COALESCE(NEW.country, '')) BETWEEN 2 AND 3
             THEN NEW.country ELSE NULL END,
        'GN'
    );

    -- Déterminer la devise
    v_currency := COALESCE(
        NULLIF(NEW.detected_currency, ''),
        get_currency_for_country(v_country),
        'GNF'
    );

    -- Créer le wallet avec la devise du pays, verrouillée
    INSERT INTO wallets (
        user_id, balance, currency, wallet_status,
        currency_locked, currency_locked_at, currency_lock_reason
    )
    VALUES (
        NEW.id, 0, v_currency, 'active',
        true, NOW(),
        'Devise assignée automatiquement selon le pays de résidence: ' || v_country
    )
    ON CONFLICT (user_id) DO NOTHING;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. RPC: complete_country_setup
--    Appelée après que l'utilisateur ait sélectionné son pays.
--    Met à jour profil + crée/met à jour wallet avec la devise correcte.
CREATE OR REPLACE FUNCTION complete_country_setup(
    p_country_code TEXT,
    p_country_name TEXT,
    p_currency     TEXT
)
RETURNS JSONB AS $$
DECLARE
    v_user_id       UUID;
    v_wallet_balance NUMERIC := 0;
    v_wallet_id     BIGINT;
    v_needs_admin   BOOLEAN := false;
    card_number     TEXT;
    card_cvv        TEXT;
    v_full_name     TEXT;
BEGIN
    -- Vérifier l'authentification
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Non authentifié');
    END IF;

    -- Valider le code pays (2 caractères)
    IF p_country_code IS NULL OR LENGTH(TRIM(p_country_code)) != 2 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Code pays invalide');
    END IF;

    -- Valider la devise (3 caractères)
    IF p_currency IS NULL OR LENGTH(TRIM(p_currency)) != 3 THEN
        RETURN jsonb_build_object('success', false, 'error', 'Code devise invalide');
    END IF;

    -- Mettre à jour le profil avec le pays sélectionné
    UPDATE profiles SET
        detected_country   = UPPER(TRIM(p_country_code)),
        country            = p_country_name,
        detected_currency  = UPPER(TRIM(p_currency)),
        profile_completed  = true,
        updated_at         = NOW()
    WHERE id = v_user_id;

    -- Vérifier si un wallet existe déjà
    SELECT id, balance INTO v_wallet_id, v_wallet_balance
    FROM wallets
    WHERE user_id = v_user_id;

    IF v_wallet_id IS NOT NULL THEN
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
            -- Solde non nul → signaler pour vérification admin
            v_needs_admin := true;
        END IF;
    ELSE
        -- Aucun wallet → le créer maintenant avec la bonne devise
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
        IF v_full_name IS NULL OR v_full_name = '' THEN
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

-- 7. AUTORISER les utilisateurs authentifiés à appeler complete_country_setup
GRANT EXECUTE ON FUNCTION complete_country_setup(TEXT, TEXT, TEXT) TO authenticated;

-- 8. VÉRIFIER et corriger les wallets existants avec devise incorrecte
--    Pour les utilisateurs Google OAuth qui ont déjà un wallet 'GNF' par défaut
--    mais ont un pays défini → corriger si balance = 0
DO $$
DECLARE
    v_rec RECORD;
    v_currency TEXT;
BEGIN
    FOR v_rec IN
        SELECT w.id AS wallet_id, w.user_id, w.balance, w.currency,
               p.detected_country, p.country, p.detected_currency
        FROM wallets w
        JOIN profiles p ON p.id = w.user_id
        WHERE w.currency_locked = false
           OR w.currency_locked IS NULL
    LOOP
        -- Ignorer si balance > 0 (ne pas changer la devise)
        IF v_rec.balance > 0 THEN CONTINUE; END IF;

        -- Déterminer la devise correcte
        IF v_rec.detected_currency IS NOT NULL AND v_rec.detected_currency != '' THEN
            v_currency := v_rec.detected_currency;
        ELSIF v_rec.detected_country IS NOT NULL AND v_rec.detected_country != '' THEN
            v_currency := get_currency_for_country(v_rec.detected_country);
        ELSIF v_rec.country IS NOT NULL AND LENGTH(v_rec.country) <= 3 THEN
            v_currency := get_currency_for_country(v_rec.country);
        ELSE
            CONTINUE; -- Pas de pays → on ne peut pas déduire la devise
        END IF;

        IF v_currency IS NULL THEN CONTINUE; END IF;

        UPDATE wallets SET
            currency             = v_currency,
            currency_locked      = true,
            currency_locked_at   = NOW(),
            currency_lock_reason = 'Correction automatique: devise selon pays profil',
            wallet_status        = 'active',
            updated_at           = NOW()
        WHERE id = v_rec.wallet_id;
    END LOOP;
END $$;
