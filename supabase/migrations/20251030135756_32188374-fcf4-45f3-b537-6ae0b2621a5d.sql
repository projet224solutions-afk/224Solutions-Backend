-- Corriger toutes les fonctions qui utilisent 'status' au lieu de 'wallet_status'

-- 1. Fonction create_user_with_wallet
CREATE OR REPLACE FUNCTION create_user_with_wallet(
  p_email TEXT,
  p_password TEXT,
  p_full_name TEXT,
  p_role user_role DEFAULT 'client'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_wallet_id uuid;
BEGIN
  -- Créer l'utilisateur dans auth.users
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, role)
  VALUES (
    p_email,
    crypt(p_password, gen_salt('bf')),
    now(),
    jsonb_build_object('provider', 'email', 'providers', array['email']),
    jsonb_build_object('full_name', p_full_name),
    'authenticated'
  )
  RETURNING id INTO v_user_id;

  -- Créer le profil
  INSERT INTO profiles (id, full_name, role)
  VALUES (v_user_id, p_full_name, p_role);

  -- Créer le wallet
  INSERT INTO wallets (user_id, balance, currency, wallet_status)
  VALUES (v_user_id, 0, 'GNF', 'active')
  RETURNING id INTO v_wallet_id;

  RETURN jsonb_build_object(
    'success', true,
    'user_id', v_user_id,
    'wallet_id', v_wallet_id
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM
    );
END;
$$;

-- 2. Fonction handle_new_user
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_full_name TEXT;
  v_role user_role;
BEGIN
  -- Extraire le nom complet et le rôle des métadonnées
  v_full_name := COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email);
  v_role := COALESCE((NEW.raw_app_meta_data->>'role')::user_role, 'client');

  -- Créer le profil
  INSERT INTO public.profiles (id, full_name, role, email)
  VALUES (NEW.id, v_full_name, v_role, NEW.email)
  ON CONFLICT (id) DO NOTHING;

  -- Créer le wallet automatiquement
  INSERT INTO public.wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
  VALUES (NEW.id, 0, 'GNF', 'active', NOW(), NOW())
  ON CONFLICT (user_id, currency) DO NOTHING;

  RETURN NEW;
END;
$$;

-- 3. Fonction get_or_create_wallet
CREATE OR REPLACE FUNCTION get_or_create_wallet(p_user_id uuid, p_currency text DEFAULT 'GNF')
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id uuid;
BEGIN
  -- Essayer de récupérer le wallet existant
  SELECT id INTO v_wallet_id
  FROM wallets
  WHERE user_id = p_user_id AND currency = p_currency;

  -- Si le wallet n'existe pas, le créer
  IF v_wallet_id IS NULL THEN
    INSERT INTO wallets (user_id, balance, currency, wallet_status, created_at, updated_at)
    VALUES (p_user_id, 0, p_currency, 'active', NOW(), NOW())
    RETURNING id INTO v_wallet_id;
  END IF;

  RETURN v_wallet_id;
END;
$$;