-- ===================================================
-- CORRECTION FORMAT ID UTILISATEUR : 3 LETTRES + 4 CHIFFRES
-- ===================================================

-- 1. Corriger la fonction generate_custom_id pour le bon format
CREATE OR REPLACE FUNCTION public.generate_custom_id()
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
  letters TEXT := '';
  numbers TEXT := '';
  i INTEGER;
  new_custom_id TEXT;
BEGIN
  -- Générer 3 lettres aléatoires (A-Z)
  FOR i IN 1..3 LOOP
    letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
  END LOOP;
  
  -- Générer 4 chiffres aléatoires (0-9)
  FOR i IN 1..4 LOOP
    numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
  END LOOP;
  
  new_custom_id := letters || numbers;
  
  -- Vérifier l'unicité
  WHILE EXISTS (SELECT 1 FROM public.user_ids WHERE user_ids.custom_id = new_custom_id) LOOP
    letters := '';
    numbers := '';
    FOR i IN 1..3 LOOP
      letters := letters || CHR(65 + (RANDOM() * 25)::INTEGER);
    END LOOP;
    FOR i IN 1..4 LOOP
      numbers := numbers || (RANDOM() * 9)::INTEGER::TEXT;
    END LOOP;
    new_custom_id := letters || numbers;
  END LOOP;
  
  RETURN new_custom_id;
END;
$function$;

-- 2. Corriger la fonction generate_user_custom_id pour le bon format
CREATE OR REPLACE FUNCTION generate_user_custom_id()
RETURNS TEXT AS $$
DECLARE
    new_id TEXT;
    letters TEXT := '';
    numbers TEXT := '';
    i INTEGER;
    counter INTEGER := 0;
BEGIN
    LOOP
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
        
        -- Vérifier l'unicité
        IF NOT EXISTS (SELECT 1 FROM user_ids WHERE custom_id = new_id) THEN
            EXIT;
        END IF;
        
        counter := counter + 1;
        -- Éviter une boucle infinie
        IF counter > 100 THEN
            new_id := 'USR' || LPAD((RANDOM() * 9999)::INTEGER::TEXT, 4, '0');
            EXIT;
        END IF;
    END LOOP;
    
    RETURN new_id;
END;
$$ LANGUAGE plpgsql;

-- 3. Mettre à jour tous les IDs existants qui ne respectent pas le format
UPDATE public.user_ids 
SET custom_id = generate_custom_id()
WHERE LENGTH(custom_id) != 7 
   OR custom_id !~ '^[A-Z]{3}[0-9]{4}$';

-- 4. Créer automatiquement un ID pour tous les utilisateurs existants qui n'en ont pas
INSERT INTO public.user_ids (user_id, custom_id)
SELECT id, generate_custom_id()
FROM auth.users 
WHERE id NOT IN (SELECT user_id FROM public.user_ids);

-- 5. Créer automatiquement un wallet pour tous les utilisateurs existants qui n'en ont pas
INSERT INTO public.wallets (user_id, balance, currency, status)
SELECT id, 0.00, 'XAF', 'active'
FROM auth.users 
WHERE id NOT IN (SELECT user_id FROM public.wallets);

-- 6. Fonction pour récupérer les informations complètes d'un utilisateur avec son ID
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
    FROM profiles p
    LEFT JOIN user_ids ui ON p.id = ui.user_id
    LEFT JOIN wallets w ON p.id = w.user_id
    LEFT JOIN virtual_cards vc ON p.id = vc.user_id
    WHERE p.id = target_user_id;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Fonction pour afficher l'ID devant le nom d'utilisateur
CREATE OR REPLACE FUNCTION get_user_display_name(target_user_id UUID)
RETURNS TEXT AS $$
DECLARE
    user_custom_id TEXT;
    user_name TEXT;
    result TEXT;
BEGIN
    -- Récupérer l'ID personnalisé
    SELECT custom_id INTO user_custom_id
    FROM user_ids
    WHERE user_id = target_user_id;
    
    -- Récupérer le nom complet
    SELECT TRIM(COALESCE(first_name, '') || ' ' || COALESCE(last_name, ''))
    INTO user_name
    FROM profiles
    WHERE id = target_user_id;
    
    -- Si pas de nom, utiliser l'email
    IF user_name IS NULL OR user_name = '' THEN
        SELECT SPLIT_PART(email, '@', 1) INTO user_name
        FROM profiles
        WHERE id = target_user_id;
    END IF;
    
    -- Construire le nom d'affichage avec l'ID devant
    IF user_custom_id IS NOT NULL THEN
        result := user_custom_id || ' - ' || COALESCE(user_name, 'Utilisateur');
    ELSE
        result := COALESCE(user_name, 'Utilisateur');
    END IF;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 8. Politique RLS pour user_ids
ALTER TABLE public.user_ids ENABLE ROW LEVEL SECURITY;

-- Supprimer les anciennes politiques si elles existent
DROP POLICY IF EXISTS "Users can view their own user_id" ON public.user_ids;
DROP POLICY IF EXISTS "Users can update their own user_id" ON public.user_ids;

-- Créer les nouvelles politiques
CREATE POLICY "Users can view their own user_id" ON public.user_ids 
FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own user_id" ON public.user_ids 
FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own user_id" ON public.user_ids 
FOR INSERT WITH CHECK (auth.uid() = user_id);

-- 9. Commentaires pour documentation
COMMENT ON FUNCTION generate_custom_id() IS 'Génère un ID utilisateur unique au format 3 lettres + 4 chiffres (ex: ABC1234)';
COMMENT ON FUNCTION get_user_display_name(UUID) IS 'Retourne le nom d''affichage avec l''ID devant (ex: ABC1234 - Jean Dupont)';
COMMENT ON TABLE user_ids IS 'Table des IDs personnalisés des utilisateurs au format 3 lettres + 4 chiffres';
