-- ==========================================
-- CORRECTION: Consolider les triggers utilisateur
-- ==========================================

-- 1. Supprimer les triggers redondants/conflictuels
DROP TRIGGER IF EXISTS on_auth_user_created_complete ON auth.users;
DROP TRIGGER IF EXISTS on_auth_user_created_wallet ON auth.users;
DROP TRIGGER IF EXISTS ensure_user_wallet_trigger ON auth.users;

-- Garder seulement on_auth_user_created (handle_new_user) et on_auth_user_created_driver

-- 2. Recréer handle_new_user pour aussi créer wallet et virtual card
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  user_role_value user_role;
  user_role_text text;
  raw_role text;
  account_type_raw text;
  generated_public_id text;
  card_number text;
BEGIN
  -- Récupérer le rôle depuis plusieurs sources possibles
  raw_role := (NEW.raw_user_meta_data::jsonb)->>'role';
  account_type_raw := (NEW.raw_user_meta_data::jsonb)->>'account_type';
  
  -- Mapper account_type vers role si nécessaire
  IF raw_role IS NOT NULL AND raw_role != '' THEN
    user_role_text := raw_role;
  ELSIF account_type_raw IS NOT NULL AND account_type_raw != '' THEN
    CASE account_type_raw
      WHEN 'marchand' THEN user_role_text := 'vendeur';
      WHEN 'merchant' THEN user_role_text := 'vendeur';
      WHEN 'livreur' THEN user_role_text := 'livreur';
      WHEN 'driver' THEN user_role_text := 'livreur';
      WHEN 'taxi_moto' THEN user_role_text := 'taxi';
      WHEN 'taxi-moto' THEN user_role_text := 'taxi';
      WHEN 'transitaire' THEN user_role_text := 'transitaire';
      WHEN 'client' THEN user_role_text := 'client';
      ELSE user_role_text := 'client';
    END CASE;
  ELSE
    user_role_text := 'client';
  END IF;

  -- Convertir en type enum avec fallback
  BEGIN
    user_role_value := user_role_text::user_role;
  EXCEPTION WHEN OTHERS THEN
    user_role_text := 'client';
    user_role_value := 'client'::user_role;
  END;

  -- Générer le public_id
  generated_public_id := public.generate_unique_public_id(user_role_text);

  -- ========== 1. Créer le profil ==========
  INSERT INTO public.profiles (
    id, email, full_name, first_name, last_name, 
    phone, public_id, custom_id, role, country, city,
    created_at, updated_at
  )
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(
      (NEW.raw_user_meta_data::jsonb)->>'full_name', 
      (NEW.raw_user_meta_data::jsonb)->>'name',
      NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '') || ' ' || COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name', '')), ''),
      split_part(NEW.email, '@', 1)
    ),
    NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '')), ''),
    NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name', '')), ''),
    COALESCE((NEW.raw_user_meta_data::jsonb)->>'phone', NEW.phone),
    generated_public_id,
    COALESCE((NEW.raw_user_meta_data::jsonb)->>'custom_id', generated_public_id),
    user_role_value,
    (NEW.raw_user_meta_data::jsonb)->>'country',
    (NEW.raw_user_meta_data::jsonb)->>'city',
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    full_name = COALESCE(profiles.full_name, EXCLUDED.full_name),
    first_name = COALESCE(profiles.first_name, EXCLUDED.first_name),
    last_name = COALESCE(profiles.last_name, EXCLUDED.last_name),
    phone = COALESCE(profiles.phone, EXCLUDED.phone),
    updated_at = NOW();

  -- ========== 2. Créer le wallet ==========
  INSERT INTO public.wallets (
    user_id,
    balance,
    currency,
    wallet_status,
    created_at,
    updated_at
  )
  VALUES (
    NEW.id,
    0,
    'GNF',
    'active',
    NOW(),
    NOW()
  )
  ON CONFLICT (user_id) DO NOTHING;

  -- ========== 3. Créer la carte virtuelle ==========
  card_number := '5224' || LPAD((RANDOM() * 999999999999)::BIGINT::TEXT, 12, '0');
  
  INSERT INTO public.virtual_cards (
    user_id,
    card_number,
    holder_name,
    expiry_date,
    cvv,
    status,
    daily_limit,
    monthly_limit
  )
  VALUES (
    NEW.id,
    card_number,
    COALESCE(
      NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '') || ' ' || COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name', '')), ''),
      'Client ' || generated_public_id
    ),
    TO_CHAR((NOW() + INTERVAL '3 years'), 'MM/YY'),
    LPAD((RANDOM() * 900 + 100)::INTEGER::TEXT, 3, '0'),
    'active',
    500000,
    2000000
  )
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- Log l'erreur mais ne pas faire échouer la création utilisateur
  RAISE LOG 'Error in handle_new_user for user %: %', NEW.id, SQLERRM;
  -- Créer au moins le profil minimal
  BEGIN
    INSERT INTO public.profiles (id, email, role, created_at, updated_at)
    VALUES (NEW.id, NEW.email, 'client', NOW(), NOW())
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG 'Failed to create minimal profile for %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;

-- 3. S'assurer que le trigger principal existe
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- 4. Supprimer les anciennes fonctions inutilisées
DROP FUNCTION IF EXISTS public.auto_create_user_wallet() CASCADE;
DROP FUNCTION IF EXISTS public.ensure_user_wallet() CASCADE;
DROP FUNCTION IF EXISTS public.handle_new_user_complete() CASCADE;

-- 5. Créer la séquence user_id_seq au cas où elle serait référencée ailleurs
CREATE SEQUENCE IF NOT EXISTS public.user_id_seq START 1000;

COMMENT ON FUNCTION public.handle_new_user() IS 'Trigger consolidé: crée profil + wallet + carte virtuelle pour chaque nouvel utilisateur';