-- PROBLÈME RACINE :
-- Lors de l'inscription par email, le téléphone est dans raw_user_meta_data.phone
-- mais auth.users.phone = NULL → le trigger lit NEW.phone = NULL → profiles.phone = NULL
-- Résultat : signInWithOtp({ phone }) ne trouve aucun utilisateur → SMS jamais envoyé

-- ════════════════════════════════════════════════════════
-- 1. METTRE À JOUR LE TRIGGER pour lire le téléphone depuis les métadonnées
-- ════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION handle_complete_user_setup()
RETURNS TRIGGER AS $$
DECLARE
    user_wallet_id UUID;
    user_custom_id TEXT;
    card_number TEXT;
    card_cvv TEXT;
    card_expiry_month TEXT;
    card_expiry_year TEXT;
    user_full_name TEXT;
    user_phone TEXT;
    meta_phone TEXT;
    phone_digits TEXT;
BEGIN
    -- Lire le téléphone : auth.users.phone en priorité, sinon raw_user_meta_data.phone
    meta_phone := NULLIF(TRIM(COALESCE(NEW.raw_user_meta_data ->> 'phone', '')), '');

    -- Normaliser le téléphone depuis les métadonnées (supprimer espaces et tirets)
    IF meta_phone IS NOT NULL THEN
        meta_phone := REGEXP_REPLACE(meta_phone, '[\s\-\(\)\.]', '', 'g');
    END IF;

    user_phone := COALESCE(
        NULLIF(TRIM(COALESCE(NEW.phone, '')), ''),
        meta_phone,
        NULL
    );

    -- Normaliser au format E.164 si pas déjà le cas
    IF user_phone IS NOT NULL AND NOT user_phone LIKE '+%' THEN
        phone_digits := REGEXP_REPLACE(user_phone, '[^\d]', '', 'g');
        IF phone_digits LIKE '00224%' AND LENGTH(phone_digits) >= 14 THEN
            user_phone := '+' || SUBSTRING(phone_digits FROM 3);
        ELSIF phone_digits LIKE '224%' AND LENGTH(phone_digits) >= 12 THEN
            user_phone := '+' || phone_digits;
        ELSIF LENGTH(phone_digits) = 9 THEN
            user_phone := '+224' || phone_digits;
        ELSE
            user_phone := '+' || phone_digits;
        END IF;
    END IF;

    -- Générer l'ID utilisateur unique
    user_custom_id := generate_user_custom_id();

    -- Construire le nom complet depuis les métadonnées
    user_full_name := TRIM(
        COALESCE(NEW.raw_user_meta_data ->> 'first_name', '') || ' ' ||
        COALESCE(NEW.raw_user_meta_data ->> 'last_name', '')
    );
    IF user_full_name = '' OR user_full_name IS NULL THEN
        user_full_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', '');
    END IF;
    IF (user_full_name = '' OR user_full_name IS NULL) AND NEW.email IS NOT NULL THEN
        user_full_name := SPLIT_PART(NEW.email, '@', 1);
    END IF;
    IF user_full_name = '' OR user_full_name IS NULL THEN
        user_full_name := COALESCE(user_phone, 'Utilisateur');
    END IF;

    -- Créer le profil utilisateur
    INSERT INTO public.profiles (
        id,
        email,
        phone,
        first_name,
        last_name,
        role
    )
    VALUES (
        NEW.id,
        NEW.email,
        user_phone,
        NULLIF(TRIM(COALESCE(NEW.raw_user_meta_data ->> 'first_name', '')), ''),
        NULLIF(TRIM(COALESCE(NEW.raw_user_meta_data ->> 'last_name', '')), ''),
        COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client')
    )
    ON CONFLICT (id) DO UPDATE SET
        email      = COALESCE(EXCLUDED.email, profiles.email),
        phone      = COALESCE(EXCLUDED.phone, profiles.phone),
        first_name = COALESCE(EXCLUDED.first_name, profiles.first_name),
        last_name  = COALESCE(EXCLUDED.last_name, profiles.last_name),
        role       = EXCLUDED.role;

    -- Créer l'ID utilisateur
    INSERT INTO public.user_ids (user_id, custom_id)
    VALUES (NEW.id, user_custom_id)
    ON CONFLICT (user_id) DO NOTHING;

    -- Créer le wallet
    INSERT INTO public.wallets (user_id, balance, currency, status)
    VALUES (NEW.id, 0.00, 'GNF', 'active')
    ON CONFLICT (user_id) DO UPDATE SET status = 'active'
    RETURNING id INTO user_wallet_id;

    IF user_wallet_id IS NULL THEN
        SELECT id INTO user_wallet_id FROM public.wallets WHERE user_id = NEW.id;
    END IF;

    -- Générer la carte virtuelle
    card_number       := generate_virtual_card_number();
    card_cvv          := generate_card_cvv();
    card_expiry_month := LPAD(EXTRACT(MONTH FROM NOW())::TEXT, 2, '0');
    card_expiry_year  := EXTRACT(YEAR FROM (NOW() + INTERVAL '3 years'))::TEXT;

    INSERT INTO public.virtual_cards (
        user_id, wallet_id, card_number, card_holder_name,
        expiry_month, expiry_year, cvv, card_type, card_status,
        daily_limit, monthly_limit
    )
    VALUES (
        NEW.id, user_wallet_id, card_number, user_full_name,
        card_expiry_month, card_expiry_year, card_cvv,
        'virtual', 'active', 500000.00, 10000000.00
    )
    ON CONFLICT (user_id) DO UPDATE SET
        card_status = 'active',
        updated_at  = NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ════════════════════════════════════════════════════════
-- 2. CORRIGER LES PROFILS EXISTANTS dont profiles.phone = NULL
--    en lisant depuis raw_user_meta_data.phone
-- ════════════════════════════════════════════════════════
UPDATE public.profiles p
SET phone = (
    SELECT
        CASE
            WHEN normalized LIKE '+%' THEN normalized
            WHEN LENGTH(REGEXP_REPLACE(normalized, '[^\d]', '', 'g')) >= 12
                AND REGEXP_REPLACE(normalized, '[^\d]', '', 'g') LIKE '224%'
                THEN '+' || REGEXP_REPLACE(normalized, '[^\d]', '', 'g')
            WHEN LENGTH(REGEXP_REPLACE(normalized, '[^\d]', '', 'g')) = 9
                THEN '+224' || REGEXP_REPLACE(normalized, '[^\d]', '', 'g')
            ELSE normalized
        END
    FROM (
        SELECT REGEXP_REPLACE(TRIM(COALESCE(au.raw_user_meta_data ->> 'phone', '')), '[\s\-\(\)\.]', '', 'g') AS normalized
        FROM auth.users au
        WHERE au.id = p.id
    ) t
    WHERE normalized IS NOT NULL AND normalized != ''
)
WHERE p.phone IS NULL
  AND EXISTS (
    SELECT 1 FROM auth.users au
    WHERE au.id = p.id
      AND au.raw_user_meta_data ->> 'phone' IS NOT NULL
      AND TRIM(au.raw_user_meta_data ->> 'phone') != ''
  );
