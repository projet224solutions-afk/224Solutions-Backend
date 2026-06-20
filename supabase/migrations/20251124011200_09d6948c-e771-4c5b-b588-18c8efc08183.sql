-- Migration: Créer automatiquement une entrée vendors pour les vendeurs
-- et corriger les vendeurs existants sans entrée vendors

-- 1. Modifier handle_new_user() pour créer une entrée vendors automatiquement
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_custom_id TEXT;
  v_role TEXT;
  v_prefix VARCHAR(3);
  v_vendor_id UUID;
BEGIN
  -- Récupérer le rôle de l'utilisateur
  v_role := COALESCE(NEW.raw_user_meta_data->>'role', 'client');
  
  -- Déterminer le préfixe en fonction du rôle
  CASE v_role
    WHEN 'vendeur' THEN v_prefix := 'VND';
    WHEN 'client' THEN v_prefix := 'CLI';
    WHEN 'livreur' THEN v_prefix := 'DLV';
    WHEN 'taxi' THEN v_prefix := 'DRV';
    WHEN 'syndicat' THEN v_prefix := 'SYD';
    WHEN 'transitaire' THEN v_prefix := 'TRA';
    WHEN 'admin' THEN v_prefix := 'ADM';
    WHEN 'agent' THEN v_prefix := 'AGT';
    WHEN 'pdg' THEN v_prefix := 'PDG';
    ELSE v_prefix := 'USR';
  END CASE;
  
  -- Générer un custom_id séquentiel standardisé
  v_custom_id := generate_sequential_id(v_prefix);
  
  -- Créer le profil utilisateur
  INSERT INTO public.profiles (
    id, 
    email, 
    full_name,
    first_name,
    last_name,
    custom_id,
    role,
    created_at,
    updated_at
  )
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.raw_user_meta_data->>'name', 'Utilisateur'),
    COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
    COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
    v_custom_id,
    v_role::user_role,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;
  
  -- Créer l'entrée dans user_ids
  INSERT INTO public.user_ids (user_id, custom_id, created_at)
  VALUES (NEW.id, v_custom_id, NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  -- Si c'est un vendeur, créer automatiquement l'entrée vendors
  IF v_role = 'vendeur' THEN
    v_vendor_id := gen_random_uuid();
    INSERT INTO public.vendors (
      id,
      user_id,
      business_name,
      email,
      phone,
      is_active,
      is_verified,
      created_at,
      updated_at
    )
    VALUES (
      v_vendor_id,
      NEW.id,
      COALESCE(NEW.raw_user_meta_data->>'business_name', NEW.raw_user_meta_data->>'full_name', 'Entreprise'),
      NEW.email,
      COALESCE(NEW.raw_user_meta_data->>'phone', ''),
      true,
      false,
      NOW(),
      NOW()
    )
    ON CONFLICT (user_id) DO NOTHING;
  END IF;
  
  -- Initialiser le wallet
  INSERT INTO public.wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
  VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW())
  ON CONFLICT (user_id, currency) DO NOTHING;
  
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS 'Trigger automatique pour créer un profil avec ID séquentiel standardisé, user_id, wallet et entrée vendors (si vendeur) lors de l''inscription';

-- 2. Fonction pour migrer les vendeurs existants sans entrée vendors
CREATE OR REPLACE FUNCTION public.migrate_vendors_without_entry()
RETURNS TABLE(user_id UUID, custom_id TEXT, vendor_id UUID, status TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user RECORD;
  v_new_vendor_id UUID;
BEGIN
  -- Parcourir tous les profils vendeur qui n'ont pas d'entrée dans vendors
  FOR v_user IN 
    SELECT p.id, p.custom_id, p.full_name, p.email, p.phone
    FROM public.profiles p
    LEFT JOIN public.vendors v ON p.id = v.user_id
    WHERE p.role = 'vendeur'
    AND v.id IS NULL
  LOOP
    -- Générer un nouvel ID pour le vendor
    v_new_vendor_id := gen_random_uuid();
    
    -- Créer l'entrée vendors
    INSERT INTO public.vendors (
      id,
      user_id,
      business_name,
      email,
      phone,
      is_active,
      is_verified,
      created_at,
      updated_at
    )
    VALUES (
      v_new_vendor_id,
      v_user.id,
      COALESCE(v_user.full_name, v_user.email, 'Entreprise'),
      v_user.email,
      COALESCE(v_user.phone, ''),
      true,
      false,
      NOW(),
      NOW()
    );
    
    user_id := v_user.id;
    custom_id := v_user.custom_id;
    vendor_id := v_new_vendor_id;
    status := 'created';
    RETURN NEXT;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.migrate_vendors_without_entry() IS 'Crée les entrées vendors manquantes pour les profils vendeur existants';

-- 3. Exécuter la migration pour les vendeurs existants
SELECT * FROM public.migrate_vendors_without_entry();