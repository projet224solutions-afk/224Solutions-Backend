-- Vérifier et créer le trigger pour setup automatique des nouveaux utilisateurs

-- D'abord, s'assurer que la fonction handle_new_user_complete existe et est correcte
CREATE OR REPLACE FUNCTION public.handle_new_user_complete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 1. Créer le profil utilisateur
  INSERT INTO public.profiles (id, email, first_name, last_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data ->> 'first_name',
    NEW.raw_user_meta_data ->> 'last_name',
    COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client')
  )
  ON CONFLICT (id) DO NOTHING;
  
  -- 2. Créer l'ID unique utilisateur
  INSERT INTO public.user_ids (user_id, custom_id)
  VALUES (NEW.id, generate_custom_id())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- 3. Créer le wallet avec bonus de bienvenue
  INSERT INTO public.wallets (user_id, balance, currency, status)
  VALUES (NEW.id, 10000, 'GNF', 'active')
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  -- 4. Créer la carte virtuelle
  DECLARE
    card_number TEXT;
    custom_id TEXT;
  BEGIN
    -- Récupérer le custom_id pour le nom de la carte
    SELECT ui.custom_id INTO custom_id
    FROM public.user_ids ui
    WHERE ui.user_id = NEW.id;
    
    -- Générer le numéro de carte
    card_number := '4*** **** **** ' || LPAD((RANDOM() * 9999)::INTEGER::TEXT, 4, '0');
    
    INSERT INTO public.virtual_cards (
      user_id,
      card_number,
      cardholder_name,
      expiry_date,
      cvv,
      status,
      card_type,
      daily_limit,
      monthly_limit
    )
    VALUES (
      NEW.id,
      card_number,
      COALESCE(NEW.raw_user_meta_data ->> 'first_name', 'Client') || ' ' || COALESCE(NEW.raw_user_meta_data ->> 'last_name', custom_id),
      (NOW() + INTERVAL '3 years')::TIMESTAMP,
      LPAD((RANDOM() * 900 + 100)::INTEGER::TEXT, 3, '0'),
      'active',
      'virtual',
      500000,
      2000000
    )
    ON CONFLICT (user_id) DO NOTHING;
  END;
  
  RETURN NEW;
END;
$$;

-- Supprimer le trigger s'il existe déjà
DROP TRIGGER IF EXISTS on_auth_user_created_complete ON auth.users;

-- Créer le trigger qui s'exécute après chaque insertion dans auth.users
CREATE TRIGGER on_auth_user_created_complete
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_complete();