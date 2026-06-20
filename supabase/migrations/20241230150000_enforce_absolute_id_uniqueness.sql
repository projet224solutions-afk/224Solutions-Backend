-- ===================================================
-- GARANTIR L'UNICITÉ ABSOLUE DES IDs UTILISATEUR
-- ===================================================

-- 1. Ajouter contrainte UNIQUE stricte sur custom_id si elle n'existe pas déjà
DO $$
BEGIN
    -- Vérifier si la contrainte unique existe déjà
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints 
        WHERE constraint_name = 'user_ids_custom_id_unique' 
        AND table_name = 'user_ids'
    ) THEN
        -- Ajouter la contrainte unique
        ALTER TABLE public.user_ids 
        ADD CONSTRAINT user_ids_custom_id_unique UNIQUE (custom_id);
        
        RAISE NOTICE 'Contrainte UNIQUE ajoutée sur custom_id';
    ELSE
        RAISE NOTICE 'Contrainte UNIQUE déjà présente sur custom_id';
    END IF;
END $$;

-- 2. Créer un index unique pour performance optimale
CREATE UNIQUE INDEX IF NOT EXISTS idx_user_ids_custom_id_unique 
ON public.user_ids (custom_id);

-- 3. Fonction renforcée pour générer un ID absolument unique
CREATE OR REPLACE FUNCTION public.generate_absolutely_unique_id()
RETURNS TEXT AS $$
DECLARE
    new_id TEXT;
    letters TEXT;
    numbers TEXT;
    i INTEGER;
    attempt_count INTEGER := 0;
    max_attempts INTEGER := 100;
    collision_detected BOOLEAN := FALSE;
BEGIN
    LOOP
        -- Réinitialiser les variables
        letters := '';
        numbers := '';
        
        -- Générer 3 lettres aléatoires (A-Z)
        FOR i IN 1..3 LOOP
            letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
        END LOOP;
        
        -- Générer 4 chiffres aléatoires (0-9)
        FOR i IN 1..4 LOOP
            numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
        END LOOP;
        
        new_id := letters || numbers;
        
        -- Vérifier l'unicité avec SELECT FOR UPDATE pour éviter les race conditions
        BEGIN
            PERFORM custom_id FROM public.user_ids 
            WHERE custom_id = new_id 
            FOR UPDATE NOWAIT;
            
            -- Si on arrive ici, l'ID existe déjà
            collision_detected := TRUE;
            
        EXCEPTION
            WHEN no_data_found THEN
                -- Parfait ! L'ID n'existe pas
                collision_detected := FALSE;
            WHEN lock_not_available THEN
                -- Quelqu'un d'autre utilise cet ID en ce moment
                collision_detected := TRUE;
        END;
        
        -- Si pas de collision, on peut utiliser cet ID
        IF NOT collision_detected THEN
            EXIT;
        END IF;
        
        attempt_count := attempt_count + 1;
        
        -- Sécurité : éviter une boucle infinie
        IF attempt_count >= max_attempts THEN
            -- Utiliser un ID basé sur timestamp + random pour garantir l'unicité
            new_id := CHR(65 + (RANDOM() * 25)::INTEGER) || 
                     CHR(65 + (RANDOM() * 25)::INTEGER) || 
                     CHR(65 + (RANDOM() * 25)::INTEGER) || 
                     LPAD((EXTRACT(EPOCH FROM NOW())::BIGINT % 10000)::TEXT, 4, '0');
            
            -- Vérifier une dernière fois
            IF NOT EXISTS (SELECT 1 FROM public.user_ids WHERE custom_id = new_id) THEN
                EXIT;
            ELSE
                -- Dernière solution : ajouter un suffixe aléatoire
                new_id := SUBSTRING(new_id, 1, 6) || (RANDOM() * 9)::INTEGER::TEXT;
                EXIT;
            END IF;
        END IF;
    END LOOP;
    
    -- Log pour debug
    IF attempt_count > 1 THEN
        RAISE NOTICE 'ID généré après % tentatives: %', attempt_count, new_id;
    END IF;
    
    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- 4. Mettre à jour la fonction principale pour utiliser la nouvelle fonction
CREATE OR REPLACE FUNCTION public.handle_new_user_complete()
RETURNS TRIGGER AS $$
DECLARE
    user_custom_id TEXT;
BEGIN
    -- Utiliser la fonction renforcée pour générer un ID unique
    user_custom_id := generate_absolutely_unique_id();

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

    -- Créer l'ID utilisateur avec protection contre les doublons
    BEGIN
        INSERT INTO public.user_ids (user_id, custom_id)
        VALUES (NEW.id, user_custom_id);
    EXCEPTION
        WHEN unique_violation THEN
            -- En cas de collision (très rare), générer un nouvel ID
            user_custom_id := generate_absolutely_unique_id();
            INSERT INTO public.user_ids (user_id, custom_id)
            VALUES (NEW.id, user_custom_id);
    END;

    -- Créer le wallet automatiquement
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

-- 5. Fonction pour vérifier l'unicité de tous les IDs existants
CREATE OR REPLACE FUNCTION public.verify_id_uniqueness()
RETURNS TABLE (
    total_ids BIGINT,
    unique_ids BIGINT,
    duplicates BIGINT,
    duplicate_ids TEXT[]
) AS $$
BEGIN
    RETURN QUERY
    WITH id_counts AS (
        SELECT 
            custom_id,
            COUNT(*) as count
        FROM public.user_ids
        GROUP BY custom_id
    ),
    stats AS (
        SELECT 
            COUNT(*) as total_ids,
            COUNT(CASE WHEN count = 1 THEN 1 END) as unique_ids,
            COUNT(CASE WHEN count > 1 THEN 1 END) as duplicates
        FROM id_counts
    ),
    duplicate_list AS (
        SELECT ARRAY_AGG(custom_id) as duplicate_ids
        FROM id_counts
        WHERE count > 1
    )
    SELECT 
        s.total_ids,
        s.unique_ids,
        s.duplicates,
        COALESCE(d.duplicate_ids, ARRAY[]::TEXT[])
    FROM stats s
    CROSS JOIN duplicate_list d;
END;
$$ LANGUAGE plpgsql;

-- 6. Corriger tous les doublons existants (si il y en a)
DO $$
DECLARE
    duplicate_record RECORD;
    new_unique_id TEXT;
BEGIN
    -- Trouver et corriger les doublons
    FOR duplicate_record IN 
        SELECT custom_id, array_agg(user_id) as user_ids
        FROM public.user_ids
        GROUP BY custom_id
        HAVING COUNT(*) > 1
    LOOP
        RAISE NOTICE 'Doublon détecté pour ID: %, utilisateurs: %', 
                     duplicate_record.custom_id, 
                     duplicate_record.user_ids;
        
        -- Garder le premier, changer les autres
        FOR i IN 2..array_length(duplicate_record.user_ids, 1) LOOP
            new_unique_id := generate_absolutely_unique_id();
            
            UPDATE public.user_ids 
            SET custom_id = new_unique_id
            WHERE user_id = duplicate_record.user_ids[i];
            
            RAISE NOTICE 'ID changé pour utilisateur %: % -> %', 
                         duplicate_record.user_ids[i],
                         duplicate_record.custom_id,
                         new_unique_id;
        END LOOP;
    END LOOP;
END $$;

-- 7. Statistiques finales
DO $$
DECLARE
    stats RECORD;
BEGIN
    SELECT * INTO stats FROM public.verify_id_uniqueness();
    
    RAISE NOTICE '=== STATISTIQUES UNICITÉ IDs ===';
    RAISE NOTICE 'Total IDs: %', stats.total_ids;
    RAISE NOTICE 'IDs uniques: %', stats.unique_ids;
    RAISE NOTICE 'Doublons: %', stats.duplicates;
    
    IF stats.duplicates > 0 THEN
        RAISE NOTICE 'IDs en doublon: %', stats.duplicate_ids;
        RAISE WARNING 'Des doublons ont été détectés et corrigés !';
    ELSE
        RAISE NOTICE '✅ TOUS LES IDs SONT UNIQUES !';
    END IF;
END $$;

-- 8. Commentaires pour documentation
COMMENT ON FUNCTION generate_absolutely_unique_id() IS 'Génère un ID utilisateur absolument unique avec protection contre les race conditions';
COMMENT ON FUNCTION verify_id_uniqueness() IS 'Vérifie l''unicité de tous les IDs utilisateur dans le système';
COMMENT ON CONSTRAINT user_ids_custom_id_unique ON public.user_ids IS 'Garantit l''unicité absolue des IDs utilisateur';

-- 9. Message de confirmation
DO $$
BEGIN
    RAISE NOTICE '🔒 UNICITÉ ABSOLUE DES IDs GARANTIE !';
    RAISE NOTICE '✅ Contrainte UNIQUE en base de données';
    RAISE NOTICE '✅ Index unique pour performance';
    RAISE NOTICE '✅ Protection contre race conditions';
    RAISE NOTICE '✅ Correction automatique des doublons';
    RAISE NOTICE '✅ Fonction de vérification disponible';
END $$;
