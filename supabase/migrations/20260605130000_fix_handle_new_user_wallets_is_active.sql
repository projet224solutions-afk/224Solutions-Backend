-- 🔴 CORRECTIF CRITIQUE — trigger handle_new_user cassé (aucun profil auto-créé)
--
-- Symptôme : la création d'utilisateur par un agent (edge create-user-by-agent)
--   échouait en 500 « Profil non créé par le trigger ». Plus largement, le trigger
--   on_auth_user_created → handle_new_user ne créait NI profil NI wallet pour les
--   nouveaux comptes auth (l'app masquait le problème car certains flux frontend
--   réinséraient le profil eux-mêmes).
--
-- Cause racine : handle_new_user fait
--     INSERT INTO public.wallets (user_id, balance, currency, is_active) ...
--   mais la table `wallets` n'a PAS de colonne `is_active` (elle a `wallet_status`).
--   L'INSERT lève une exception → le bloc `EXCEPTION WHEN OTHERS` l'avale et fait
--   RETURN NEW → TOUT le travail de la fonction (y compris l'INSERT profiles qui
--   précède) est ROLLBACK → le nouvel utilisateur se retrouve sans profil.
--
-- Correctif : retirer la colonne inexistante `is_active` de l'INSERT wallets.
--   (wallet_status a sa valeur par défaut 'active'.) Aucune autre logique changée.

CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  user_role_value      user_role;
  user_role_text       TEXT;
  raw_role             TEXT;
  account_type_raw     TEXT;
  generated_public_id  TEXT;
  v_detected_country   TEXT;
  v_detected_currency  TEXT;
  v_wallet_currency    TEXT;
BEGIN
  raw_role         := (NEW.raw_user_meta_data::jsonb)->>'role';
  account_type_raw := (NEW.raw_user_meta_data::jsonb)->>'account_type';

  IF raw_role IS NOT NULL AND raw_role != '' THEN
    user_role_text := raw_role;
  ELSIF account_type_raw IS NOT NULL AND account_type_raw != '' THEN
    CASE account_type_raw
      WHEN 'marchand'    THEN user_role_text := 'vendeur';
      WHEN 'merchant'    THEN user_role_text := 'vendeur';
      WHEN 'livreur'     THEN user_role_text := 'livreur';
      WHEN 'driver'      THEN user_role_text := 'livreur';
      WHEN 'taxi_moto'   THEN user_role_text := 'taxi';
      WHEN 'taxi-moto'   THEN user_role_text := 'taxi';
      WHEN 'transitaire' THEN user_role_text := 'transitaire';
      WHEN 'prestataire' THEN user_role_text := 'prestataire';
      WHEN 'service'     THEN user_role_text := 'prestataire';
      WHEN 'client'      THEN user_role_text := 'client';
      ELSE                    user_role_text := 'client';
    END CASE;
  ELSE
    user_role_text := 'client';
  END IF;

  -- Validation explicite: evite conversion silencieuse de roles inconnus en 'client'
  IF user_role_text NOT IN (
    'client','vendeur','livreur','taxi','driver','syndicat','bureau',
    'transitaire','prestataire','pdg','admin','ceo','agent','vendor_agent',
    'actionnaire'
  ) THEN
    RAISE LOG '[handle_new_user] Role inconnu % pour user %, remplace par client', user_role_text, NEW.id;
    user_role_text := 'client';
  END IF;

  BEGIN
    user_role_value := user_role_text::user_role;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[handle_new_user] Erreur cast role % pour user %: %. Fallback client.', user_role_text, NEW.id, SQLERRM;
    user_role_text  := 'client';
    user_role_value := 'client'::user_role;
  END;

  generated_public_id := public.generate_unique_public_id(user_role_text);

  v_detected_country := NULLIF(
    UPPER(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'detected_country', ''))), ''
  );
  v_detected_currency := NULLIF(
    UPPER(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'detected_currency', ''))), ''
  );

  IF v_detected_country IS NOT NULL AND LENGTH(v_detected_country) != 2 THEN
    v_detected_country := NULL;
  END IF;
  IF v_detected_currency IS NOT NULL AND LENGTH(v_detected_currency) != 3 THEN
    v_detected_currency := NULL;
  END IF;

  INSERT INTO public.profiles (
    id, email, first_name, last_name, role, phone,
    public_id, country,
    detected_country, detected_currency, is_active, created_at, updated_at
  )
  VALUES (
    NEW.id,
    LOWER(TRIM(COALESCE(NEW.email, ''))),
    COALESCE(
      (NEW.raw_user_meta_data::jsonb)->>'first_name',
      SPLIT_PART(COALESCE((NEW.raw_user_meta_data::jsonb)->>'full_name', ''), ' ', 1),
      ''
    ),
    COALESCE(
      (NEW.raw_user_meta_data::jsonb)->>'last_name',
      NULLIF(TRIM(SUBSTRING(COALESCE((NEW.raw_user_meta_data::jsonb)->>'full_name', '') FROM POSITION(' ' IN COALESCE((NEW.raw_user_meta_data::jsonb)->>'full_name', '')))), ''),
      ''
    ),
    user_role_value,
    COALESCE((NEW.raw_user_meta_data::jsonb)->>'phone', NULL),
    generated_public_id,
    NULL,
    v_detected_country,
    v_detected_currency,
    true,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO NOTHING;

  v_wallet_currency := COALESCE(v_detected_currency, 'GNF');

  -- CORRECTIF : `wallets` n'a pas de colonne is_active → on l'enlève (wallet_status
  -- prend sa valeur par défaut). Sans ça, tout le trigger échouait silencieusement.
  INSERT INTO public.wallets (user_id, balance, currency)
  VALUES (NEW.id, 0, v_wallet_currency)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'Error in handle_new_user for user %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$function$;
