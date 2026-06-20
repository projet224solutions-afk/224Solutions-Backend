-- ===================================================
-- ASSURER LA CRÉATION AUTOMATIQUE DE WALLET + ID
-- ===================================================

-- 1. Fonction pour créer automatiquement wallet + ID à l'inscription
CREATE OR REPLACE FUNCTION public.handle_new_user_complete()
RETURNS TRIGGER AS $$
DECLARE
    user_custom_id TEXT;
    letters TEXT := '';
    numbers TEXT := '';
    i INTEGER;
BEGIN
    -- Générer un ID utilisateur unique (3 lettres + 4 chiffres)
    FOR i IN 1..3 LOOP
        letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
    END LOOP;
    
    FOR i IN 1..4 LOOP
        numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
    
    user_custom_id := letters || numbers;
    
    -- Vérifier l'unicité de l'ID
    WHILE EXISTS (SELECT 1 FROM public.user_ids WHERE custom_id = user_custom_id) LOOP
        letters := '';
        numbers := '';
        FOR i IN 1..3 LOOP
            letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
        END LOOP;
        FOR i IN 1..4 LOOP
            numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
        END LOOP;
        user_custom_id := letters || numbers;
    END LOOP;

    -- Créer le profil utilisateur
    INSERT INTO public.profiles (
        id, 
        email, 
        first_name, 
        last_name, 
        role,
        phone,
        country
    )
    VALUES (
        NEW.id,
        NEW.email,
        NEW.raw_user_meta_data ->> 'first_name',
        NEW.raw_user_meta_data ->> 'last_name',
        COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client'),
        NEW.raw_user_meta_data ->> 'phone',
        NEW.raw_user_meta_data ->> 'country'
    )
    ON CONFLICT (id) DO UPDATE SET
        email = EXCLUDED.email,
        first_name = EXCLUDED.first_name,
        last_name = EXCLUDED.last_name,
        role = EXCLUDED.role,
        phone = EXCLUDED.phone,
        country = EXCLUDED.country;

    -- Créer l'ID utilisateur automatiquement
    INSERT INTO public.user_ids (user_id, custom_id)
    VALUES (NEW.id, user_custom_id)
    ON CONFLICT (user_id) DO UPDATE SET
        custom_id = EXCLUDED.custom_id;

    -- Créer le wallet automatiquement (sauf pour les vendeurs qui ont déjà le leur)
    INSERT INTO public.wallets (
        user_id, 
        balance, 
        currency, 
        status
    )
    VALUES (
        NEW.id, 
        CASE 
            WHEN COALESCE((NEW.raw_user_meta_data ->> 'role'), 'client') = 'vendeur' THEN 50000.00
            ELSE 10000.00
        END,
        'XAF', 
        'active'
    )
    ON CONFLICT (user_id) DO UPDATE SET
        status = 'active',
        balance = CASE 
            WHEN EXCLUDED.balance > wallets.balance THEN EXCLUDED.balance
            ELSE wallets.balance
        END;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Supprimer l'ancien trigger et créer le nouveau
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user_complete();

-- 3. Créer automatiquement wallet + ID pour tous les utilisateurs existants qui n'en ont pas
DO $$
DECLARE
    user_record RECORD;
    user_custom_id TEXT;
    letters TEXT;
    numbers TEXT;
    i INTEGER;
BEGIN
    -- Pour chaque utilisateur sans wallet ou sans ID
    FOR user_record IN 
        SELECT DISTINCT u.id, u.email, p.role
        FROM auth.users u
        LEFT JOIN public.profiles p ON u.id = p.id
        WHERE u.id NOT IN (SELECT user_id FROM public.wallets WHERE user_id IS NOT NULL)
           OR u.id NOT IN (SELECT user_id FROM public.user_ids WHERE user_id IS NOT NULL)
    LOOP
        -- Générer un ID unique si manquant
        IF NOT EXISTS (SELECT 1 FROM public.user_ids WHERE user_id = user_record.id) THEN
            letters := '';
            numbers := '';
            
            FOR i IN 1..3 LOOP
                letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
            END LOOP;
            
            FOR i IN 1..4 LOOP
                numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
            END LOOP;
            
            user_custom_id := letters || numbers;
            
            -- Vérifier l'unicité
            WHILE EXISTS (SELECT 1 FROM public.user_ids WHERE custom_id = user_custom_id) LOOP
                letters := '';
                numbers := '';
                FOR i IN 1..3 LOOP
                    letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
                END LOOP;
                FOR i IN 1..4 LOOP
                    numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
                END LOOP;
                user_custom_id := letters || numbers;
            END LOOP;
            
            INSERT INTO public.user_ids (user_id, custom_id)
            VALUES (user_record.id, user_custom_id);
        END IF;

        -- Créer le wallet si manquant
        IF NOT EXISTS (SELECT 1 FROM public.wallets WHERE user_id = user_record.id) THEN
            INSERT INTO public.wallets (user_id, balance, currency, status)
            VALUES (
                user_record.id,
                CASE 
                    WHEN COALESCE(user_record.role, 'client') = 'vendeur' THEN 50000.00
                    ELSE 10000.00
                END,
                'XAF',
                'active'
            );
        END IF;
    END LOOP;
END $$;

-- 4. Fonction pour obtenir les détails de transaction d'un wallet
CREATE OR REPLACE FUNCTION get_wallet_transactions(wallet_user_id UUID, limit_count INTEGER DEFAULT 10)
RETURNS TABLE (
    id UUID,
    amount DECIMAL,
    transaction_type TEXT,
    description TEXT,
    created_at TIMESTAMP,
    status TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        t.id,
        t.amount,
        t.transaction_type,
        t.description,
        t.created_at,
        t.status
    FROM wallet_transactions t
    JOIN wallets w ON t.wallet_id = w.id
    WHERE w.user_id = wallet_user_id
    ORDER BY t.created_at DESC
    LIMIT limit_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 5. Créer quelques transactions de test pour les wallets existants
INSERT INTO wallet_transactions (wallet_id, amount, transaction_type, description, status)
SELECT 
    w.id,
    10000.00,
    'credit',
    'Bonus de bienvenue 224Solutions',
    'completed'
FROM wallets w
WHERE NOT EXISTS (
    SELECT 1 FROM wallet_transactions wt WHERE wt.wallet_id = w.id
);

-- 6. Commentaires pour documentation
COMMENT ON FUNCTION handle_new_user_complete() IS 'Crée automatiquement profil + ID + wallet pour chaque nouvel utilisateur';
COMMENT ON FUNCTION get_wallet_transactions(UUID, INTEGER) IS 'Récupère les transactions d''un wallet utilisateur';

-- 7. Vérifier que tout fonctionne
DO $$
BEGIN
    RAISE NOTICE 'Migration terminée - Création automatique wallet + ID activée';
    RAISE NOTICE 'Utilisateurs avec wallet: %', (SELECT COUNT(*) FROM wallets);
    RAISE NOTICE 'Utilisateurs avec ID: %', (SELECT COUNT(*) FROM user_ids);
END $$;
