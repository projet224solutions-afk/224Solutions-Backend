-- ===================================================
-- CORRECTION CRÉATION AUTOMATIQUE USER + WALLET + ID
-- ===================================================

-- 1. Nettoyer les anciens triggers pour éviter les conflits
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
DROP TRIGGER IF EXISTS auto_create_wallet_and_card ON profiles;

-- 2. Fonction pour générer un ID utilisateur unique
CREATE OR REPLACE FUNCTION generate_user_custom_id()
RETURNS TEXT AS $$
DECLARE
    new_id TEXT;
    counter INTEGER := 0;
BEGIN
    LOOP
        -- Format: USR + 7 chiffres (ex: USR0001234)
        new_id := 'USR' || LPAD((RANDOM() * 9999999)::INTEGER::TEXT, 7, '0');
        
        -- Vérifier l'unicité
        IF NOT EXISTS (SELECT 1 FROM user_ids WHERE custom_id = new_id) THEN
            EXIT;
        END IF;
        
        counter := counter + 1;
        -- Éviter une boucle infinie
        IF counter > 100 THEN
            new_id := 'USR' || EXTRACT(EPOCH FROM NOW())::INTEGER::TEXT;
            EXIT;
        END IF;
    END LOOP;
    
    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- 3. Fonction pour générer un numéro de carte virtuelle
CREATE OR REPLACE FUNCTION generate_virtual_card_number()
RETURNS TEXT AS $$
BEGIN
    -- Format: 2245 XXXX XXXX XXXX (commence par 2245 pour 224Solutions)
    RETURN '2245' || LPAD((RANDOM() * 9999)::INTEGER::TEXT, 4, '0') || 
           LPAD((RANDOM() * 9999)::INTEGER::TEXT, 4, '0') || 
           LPAD((RANDOM() * 9999)::INTEGER::TEXT, 4, '0');
END;
$$ LANGUAGE plpgsql;

-- 4. Fonction pour générer un CVV
CREATE OR REPLACE FUNCTION generate_card_cvv()
RETURNS TEXT AS $$
BEGIN
    RETURN LPAD((RANDOM() * 999)::INTEGER::TEXT, 3, '0');
END;
$$ LANGUAGE plpgsql;

-- 5. Fonction principale de création automatique complète
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
BEGIN
    -- Générer l'ID utilisateur unique
    user_custom_id := generate_user_custom_id();
    
    -- Créer le profil utilisateur
    INSERT INTO public.profiles (
        id, 
        email, 
        first_name, 
        last_name, 
        role
    )
    VALUES (
        NEW.id,
        NEW.email,
        NEW.raw_user_meta_data ->> 'first_name',
        NEW.raw_user_meta_data ->> 'last_name',
        COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client')
    )
    ON CONFLICT (id) DO UPDATE SET
        email = EXCLUDED.email,
        first_name = EXCLUDED.first_name,
        last_name = EXCLUDED.last_name,
        role = EXCLUDED.role;
    
    -- Créer l'ID utilisateur dans la table user_ids
    INSERT INTO public.user_ids (user_id, custom_id)
    VALUES (NEW.id, user_custom_id)
    ON CONFLICT (user_id) DO UPDATE SET
        custom_id = EXCLUDED.custom_id;
    
    -- Créer le wallet automatiquement
    INSERT INTO public.wallets (
        user_id, 
        balance, 
        currency, 
        status
    )
    VALUES (
        NEW.id, 
        0.00, 
        'XAF', 
        'active'
    )
    ON CONFLICT (user_id) DO UPDATE SET
        status = 'active'
    RETURNING id INTO user_wallet_id;
    
    -- Si le wallet existait déjà, récupérer son ID
    IF user_wallet_id IS NULL THEN
        SELECT id INTO user_wallet_id FROM public.wallets WHERE user_id = NEW.id;
    END IF;
    
    -- Générer les données de la carte virtuelle
    card_number := generate_virtual_card_number();
    card_cvv := generate_card_cvv();
    card_expiry_month := LPAD(EXTRACT(MONTH FROM NOW())::TEXT, 2, '0');
    card_expiry_year := EXTRACT(YEAR FROM (NOW() + INTERVAL '3 years'))::TEXT;
    
    -- Construire le nom complet
    user_full_name := TRIM(COALESCE(NEW.raw_user_meta_data ->> 'first_name', '') || ' ' || 
                          COALESCE(NEW.raw_user_meta_data ->> 'last_name', ''));
    IF user_full_name = '' OR user_full_name IS NULL THEN
        user_full_name := SPLIT_PART(NEW.email, '@', 1);
    END IF;
    
    -- Créer la carte virtuelle automatiquement
    INSERT INTO public.virtual_cards (
        user_id,
        wallet_id,
        card_number,
        card_holder_name,
        expiry_month,
        expiry_year,
        cvv,
        card_type,
        card_status,
        daily_limit,
        monthly_limit
    )
    VALUES (
        NEW.id,
        user_wallet_id,
        card_number,
        user_full_name,
        card_expiry_month,
        card_expiry_year,
        card_cvv,
        'virtual',
        'active',
        500000.00,  -- Limite journalière 500k XAF
        10000000.00 -- Limite mensuelle 10M XAF
    )
    ON CONFLICT (user_id) DO UPDATE SET
        card_status = 'active',
        updated_at = NOW();
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 6. Créer le trigger principal
CREATE TRIGGER on_auth_user_created_complete
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION handle_complete_user_setup();

-- 7. Créer les wallets et IDs pour les utilisateurs existants qui n'en ont pas
DO $$
DECLARE
    user_record RECORD;
    user_wallet_id UUID;
    user_custom_id TEXT;
    card_number TEXT;
    card_cvv TEXT;
    user_full_name TEXT;
BEGIN
    -- Pour chaque utilisateur existant
    FOR user_record IN 
        SELECT u.id, u.email, p.first_name, p.last_name
        FROM auth.users u
        LEFT JOIN public.profiles p ON u.id = p.id
    LOOP
        -- Créer wallet s'il n'existe pas
        IF NOT EXISTS (SELECT 1 FROM public.wallets WHERE user_id = user_record.id) THEN
            INSERT INTO public.wallets (user_id, balance, currency, status)
            VALUES (user_record.id, 0.00, 'XAF', 'active')
            RETURNING id INTO user_wallet_id;
        ELSE
            SELECT id INTO user_wallet_id FROM public.wallets WHERE user_id = user_record.id;
        END IF;
        
        -- Créer ID utilisateur s'il n'existe pas
        IF NOT EXISTS (SELECT 1 FROM public.user_ids WHERE user_id = user_record.id) THEN
            user_custom_id := generate_user_custom_id();
            INSERT INTO public.user_ids (user_id, custom_id)
            VALUES (user_record.id, user_custom_id);
        END IF;
        
        -- Créer carte virtuelle s'elle n'existe pas
        IF NOT EXISTS (SELECT 1 FROM public.virtual_cards WHERE user_id = user_record.id) THEN
            card_number := generate_virtual_card_number();
            card_cvv := generate_card_cvv();
            
            user_full_name := TRIM(COALESCE(user_record.first_name, '') || ' ' || 
                                  COALESCE(user_record.last_name, ''));
            IF user_full_name = '' OR user_full_name IS NULL THEN
                user_full_name := SPLIT_PART(user_record.email, '@', 1);
            END IF;
            
            INSERT INTO public.virtual_cards (
                user_id,
                wallet_id,
                card_number,
                card_holder_name,
                expiry_month,
                expiry_year,
                cvv,
                card_type,
                card_status,
                daily_limit,
                monthly_limit
            )
            VALUES (
                user_record.id,
                user_wallet_id,
                card_number,
                user_full_name,
                LPAD(EXTRACT(MONTH FROM NOW())::TEXT, 2, '0'),
                EXTRACT(YEAR FROM (NOW() + INTERVAL '3 years'))::TEXT,
                card_cvv,
                'virtual',
                'active',
                500000.00,
                10000000.00
            );
        END IF;
    END LOOP;
END $$;

-- 8. Vérifier que les tables existent et créer les index nécessaires
CREATE INDEX IF NOT EXISTS idx_wallets_user_id ON public.wallets(user_id);
CREATE INDEX IF NOT EXISTS idx_user_ids_user_id ON public.user_ids(user_id);
CREATE INDEX IF NOT EXISTS idx_user_ids_custom_id ON public.user_ids(custom_id);
CREATE INDEX IF NOT EXISTS idx_virtual_cards_user_id ON public.virtual_cards(user_id);
CREATE INDEX IF NOT EXISTS idx_virtual_cards_wallet_id ON public.virtual_cards(wallet_id);

-- 9. RLS Policies pour sécuriser l'accès
-- Wallets
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own wallet" ON public.wallets;
CREATE POLICY "Users can view own wallet" ON public.wallets 
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own wallet" ON public.wallets;
CREATE POLICY "Users can update own wallet" ON public.wallets 
    FOR UPDATE USING (auth.uid() = user_id);

-- User IDs
ALTER TABLE public.user_ids ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own ID" ON public.user_ids;
CREATE POLICY "Users can view own ID" ON public.user_ids 
    FOR SELECT USING (auth.uid() = user_id);

-- Virtual Cards
ALTER TABLE public.virtual_cards ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own cards" ON public.virtual_cards;
CREATE POLICY "Users can view own cards" ON public.virtual_cards 
    FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own cards" ON public.virtual_cards;
CREATE POLICY "Users can update own cards" ON public.virtual_cards 
    FOR UPDATE USING (auth.uid() = user_id);

-- 10. Fonction pour récupérer les infos complètes utilisateur
CREATE OR REPLACE FUNCTION get_user_complete_info(target_user_id UUID)
RETURNS JSON AS $$
DECLARE
    result JSON;
BEGIN
    SELECT json_build_object(
        'user_id', p.id,
        'email', p.email,
        'first_name', p.first_name,
        'last_name', p.last_name,
        'role', p.role,
        'custom_id', ui.custom_id,
        'wallet', json_build_object(
            'id', w.id,
            'balance', w.balance,
            'currency', w.currency,
            'status', w.status
        ),
        'virtual_card', json_build_object(
            'id', vc.id,
            'card_number', vc.card_number,
            'card_holder_name', vc.card_holder_name,
            'expiry_month', vc.expiry_month,
            'expiry_year', vc.expiry_year,
            'card_status', vc.card_status,
            'daily_limit', vc.daily_limit,
            'monthly_limit', vc.monthly_limit
        )
    ) INTO result
    FROM public.profiles p
    LEFT JOIN public.user_ids ui ON p.id = ui.user_id
    LEFT JOIN public.wallets w ON p.id = w.user_id
    LEFT JOIN public.virtual_cards vc ON p.id = vc.user_id
    WHERE p.id = target_user_id;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 11. Logs pour debugging
INSERT INTO public.system_logs (log_level, message, details) 
VALUES ('INFO', 'Migration applied: Auto user creation fixed', 
        json_build_object(
            'migration', '20241002000000_fix_auto_user_creation',
            'timestamp', NOW(),
            'features', ARRAY['auto_wallet', 'auto_user_id', 'auto_virtual_card']
        ));
