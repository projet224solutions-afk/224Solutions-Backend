-- Supprimer le trigger en double
DROP TRIGGER IF EXISTS on_auth_user_created_complete ON auth.users;

-- Corriger la fonction pour utiliser le bon nom de colonne
CREATE OR REPLACE FUNCTION public.handle_new_user_complete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  card_number TEXT;
  custom_id TEXT;
BEGIN
  -- Créer le profil
  INSERT INTO public.profiles (id, email, first_name, last_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    NEW.raw_user_meta_data ->> 'first_name',
    NEW.raw_user_meta_data ->> 'last_name',
    COALESCE((NEW.raw_user_meta_data ->> 'role')::user_role, 'client')
  )
  ON CONFLICT (id) DO NOTHING;
  
  -- Créer l'ID utilisateur
  INSERT INTO public.user_ids (user_id, custom_id)
  VALUES (NEW.id, generate_custom_id())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- Créer le wallet
  INSERT INTO public.wallets (user_id, balance, currency)
  VALUES (NEW.id, 10000, 'GNF')
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  -- Récupérer le custom_id
  SELECT ui.custom_id INTO custom_id
  FROM public.user_ids ui
  WHERE ui.user_id = NEW.id;
  
  -- Générer le numéro de carte
  card_number := '2245' || LPAD((RANDOM() * 999999999999)::BIGINT::TEXT, 12, '0');
  
  -- Créer la carte virtuelle (holder_name au lieu de cardholder_name)
  INSERT INTO public.virtual_cards (
    user_id,
    card_number,
    holder_name,
    expiry_date,
    cvv,
    daily_limit,
    monthly_limit
  )
  VALUES (
    NEW.id,
    card_number,
    COALESCE(NEW.raw_user_meta_data ->> 'first_name', 'Client') || ' ' || COALESCE(NEW.raw_user_meta_data ->> 'last_name', custom_id),
    TO_CHAR((NOW() + INTERVAL '3 years'), 'MM/YY'),
    LPAD((RANDOM() * 900 + 100)::INTEGER::TEXT, 3, '0'),
    500000,
    2000000
  )
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$function$;