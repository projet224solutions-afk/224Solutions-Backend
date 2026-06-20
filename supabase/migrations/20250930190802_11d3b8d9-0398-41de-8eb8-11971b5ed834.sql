-- Corriger le trigger pour ne plus utiliser card_type qui n'existe pas
CREATE OR REPLACE FUNCTION public.handle_new_user_complete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  card_number TEXT;
  custom_id TEXT;
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
  INSERT INTO public.wallets (user_id, balance, currency)
  VALUES (NEW.id, 10000, 'GNF')
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  -- 4. Créer la carte virtuelle (sans card_type)
  SELECT ui.custom_id INTO custom_id
  FROM public.user_ids ui
  WHERE ui.user_id = NEW.id;
  
  -- Générer le numéro de carte simple
  card_number := '2245' || LPAD((RANDOM() * 999999999999)::BIGINT::TEXT, 12, '0');
  
  INSERT INTO public.virtual_cards (
    user_id,
    card_number,
    cardholder_name,
    expiry_date,
    cvv,
    daily_limit,
    monthly_limit
  )
  VALUES (
    NEW.id,
    card_number,
    COALESCE(NEW.raw_user_meta_data ->> 'first_name', 'Client') || ' ' || COALESCE(NEW.raw_user_meta_data ->> 'last_name', custom_id),
    (NOW() + INTERVAL '3 years')::TIMESTAMP,
    LPAD((RANDOM() * 900 + 100)::INTEGER::TEXT, 3, '0'),
    500000,
    2000000
  )
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- Créer automatiquement un vendor pour tous les utilisateurs avec role 'vendeur'
INSERT INTO public.vendors (user_id, business_name, description, rating)
SELECT 
  p.id,
  COALESCE(p.first_name || ' ' || p.last_name, 'Commerce ' || ui.custom_id),
  'Vendeur professionnel sur 224Solutions',
  5.0
FROM public.profiles p
JOIN public.user_ids ui ON ui.user_id = p.id
WHERE p.role = 'vendeur'
AND NOT EXISTS (
  SELECT 1 FROM public.vendors v WHERE v.user_id = p.id
);

-- Créer des paramètres POS pour tous les nouveaux vendors
INSERT INTO public.pos_settings (vendor_id, company_name, currency, tax_rate, tax_enabled)
SELECT 
  v.user_id,
  COALESCE(p.first_name || ' ' || p.last_name, 'Mon Commerce'),
  'FCFA',
  0.18,
  true
FROM public.vendors v
JOIN public.profiles p ON v.user_id = p.id
WHERE NOT EXISTS (
  SELECT 1 FROM public.pos_settings ps WHERE ps.vendor_id = v.user_id
);