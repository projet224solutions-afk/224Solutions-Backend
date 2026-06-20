-- profiles.email est UNIQUE NOT NULL, ce qui bloque les inscriptions par téléphone
-- (email = NULL pour les utilisateurs téléphone → violation NOT NULL → trigger échoue → compte non créé)

-- 1. Rendre email nullable dans profiles
ALTER TABLE public.profiles ALTER COLUMN email DROP NOT NULL;

-- 2. Mettre à jour le trigger pour gérer correctement les utilisateurs téléphone
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
BEGIN
    -- Récupérer le téléphone depuis auth.users (colonne phone)
    user_phone := NEW.phone;

    -- Générer l'ID utilisateur unique
    user_custom_id := generate_user_custom_id();

    -- Construire le nom complet depuis les métadonnées
    user_full_name := TRIM(
        COALESCE(NEW.raw_user_meta_data ->> 'first_name', '') || ' ' ||
        COALESCE(NEW.raw_user_meta_data ->> 'last_name', '')
    );
    -- Fallback : full_name dans les métadonnées
    IF user_full_name = '' OR user_full_name IS NULL THEN
        user_full_name := COALESCE(NEW.raw_user_meta_data ->> 'full_name', '');
    END IF;
    -- Fallback : partie locale de l'email
    IF (user_full_name = '' OR user_full_name IS NULL) AND NEW.email IS NOT NULL THEN
        user_full_name := SPLIT_PART(NEW.email, '@', 1);
    END IF;
    -- Fallback : numéro de téléphone
    IF user_full_name = '' OR user_full_name IS NULL THEN
        user_full_name := COALESCE(user_phone, 'Utilisateur');
    END IF;

    -- Créer le profil utilisateur (email nullable maintenant)
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
        NEW.email,   -- NULL pour les utilisateurs téléphone, c'est OK maintenant
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
