-- =================================================================
-- MIGRATION: Propagation du pays à l'inscription (email + OAuth)
-- Date: 2026-05-13
-- Problème: handle_new_user() n'incluait pas detected_country dans
--   le profil → trigger_create_wallet_on_profile créait le wallet
--   avec GNF par défaut même si l'utilisateur est au Cameroun/Sénégal.
-- Solution:
--   1. handle_new_user() lit detected_country/detected_currency depuis
--      raw_user_meta_data et les inclut dans l'INSERT profiles.
--   2. Le wallet direct dans handle_new_user() utilise aussi la bonne devise.
--   3. Nouveau trigger AFTER UPDATE sur profiles : si detected_country
--      est mis à jour (via geo-detect post-OAuth) et que le wallet est
--      encore en GNF + balance=0, on corrige la devise immédiatement.
-- =================================================================

-- ─────────────────────────────────────────────────────────────────
-- 1. RECRÉER handle_new_user avec propagation detected_country
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  user_role_value      user_role;
  user_role_text       TEXT;
  raw_role             TEXT;
  account_type_raw     TEXT;
  generated_public_id  TEXT;
  card_number          TEXT;
  v_detected_country   TEXT;
  v_detected_currency  TEXT;
  v_wallet_currency    TEXT;
BEGIN
  -- ── Rôle utilisateur ──────────────────────────────────────────
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

  BEGIN
    user_role_value := user_role_text::user_role;
  EXCEPTION WHEN OTHERS THEN
    user_role_text  := 'client';
    user_role_value := 'client'::user_role;
  END;

  -- ── Identifiant public ────────────────────────────────────────
  generated_public_id := public.generate_unique_public_id(user_role_text);

  -- ── Pays & devise depuis les métadonnées ─────────────────────
  -- Le frontend passe ces valeurs depuis le cache géo-détection
  v_detected_country := NULLIF(
    UPPER(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'detected_country', ''))), ''
  );
  v_detected_currency := NULLIF(
    UPPER(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'detected_currency', ''))), ''
  );

  -- Valider le format: 2 chars pour pays, 3 chars pour devise
  IF v_detected_country IS NOT NULL AND LENGTH(v_detected_country) != 2 THEN
    v_detected_country := NULL;
  END IF;
  IF v_detected_currency IS NOT NULL AND LENGTH(v_detected_currency) != 3 THEN
    v_detected_currency := NULL;
  END IF;

  -- Déterminer la devise du wallet
  IF v_detected_currency IS NOT NULL THEN
    v_wallet_currency := v_detected_currency;
  ELSIF v_detected_country IS NOT NULL THEN
    v_wallet_currency := COALESCE(get_currency_for_country(v_detected_country), 'GNF');
  ELSE
    -- Fallback : tenter depuis le champ "country" libre si disponible
    DECLARE
      v_meta_country TEXT;
    BEGIN
      v_meta_country := NULLIF(
        UPPER(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'country', ''))), ''
      );
      IF v_meta_country IS NOT NULL AND LENGTH(v_meta_country) = 2 THEN
        v_wallet_currency := COALESCE(get_currency_for_country(v_meta_country), 'GNF');
      ELSE
        v_wallet_currency := 'GNF';
      END IF;
    END;
  END IF;

  -- ── 1. Créer le profil ────────────────────────────────────────
  INSERT INTO public.profiles (
    id, email, full_name, first_name, last_name,
    phone, public_id, custom_id, role, country, city,
    detected_country, detected_currency,
    created_at, updated_at
  )
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(
      (NEW.raw_user_meta_data::jsonb)->>'full_name',
      (NEW.raw_user_meta_data::jsonb)->>'name',
      NULLIF(TRIM(
        COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '') || ' ' ||
        COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name', '')
      ), ''),
      split_part(NEW.email, '@', 1)
    ),
    NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '')), ''),
    NULLIF(TRIM(COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name',  '')), ''),
    COALESCE((NEW.raw_user_meta_data::jsonb)->>'phone', NEW.phone),
    generated_public_id,
    COALESCE((NEW.raw_user_meta_data::jsonb)->>'custom_id', generated_public_id),
    user_role_value,
    (NEW.raw_user_meta_data::jsonb)->>'country',
    (NEW.raw_user_meta_data::jsonb)->>'city',
    v_detected_country,
    v_detected_currency,
    NOW(),
    NOW()
  )
  ON CONFLICT (id) DO UPDATE SET
    email             = EXCLUDED.email,
    full_name         = COALESCE(profiles.full_name,         EXCLUDED.full_name),
    first_name        = COALESCE(profiles.first_name,        EXCLUDED.first_name),
    last_name         = COALESCE(profiles.last_name,         EXCLUDED.last_name),
    phone             = COALESCE(profiles.phone,             EXCLUDED.phone),
    detected_country  = COALESCE(profiles.detected_country,  EXCLUDED.detected_country),
    detected_currency = COALESCE(profiles.detected_currency, EXCLUDED.detected_currency),
    updated_at        = NOW();

  -- ── 2. Créer le wallet avec la bonne devise ───────────────────
  -- trigger_create_wallet_on_profile se déclenche déjà lors de l'INSERT
  -- profiles ci-dessus. Cet INSERT est un filet de sécurité en cas de
  -- conflit ou d'absence du trigger secondaire.
  INSERT INTO public.wallets (
    user_id, balance, currency, wallet_status,
    currency_locked, currency_locked_at, currency_lock_reason,
    created_at, updated_at
  )
  VALUES (
    NEW.id, 0, v_wallet_currency, 'active',
    true, NOW(),
    'Devise assignée automatiquement lors de l''inscription depuis '
      || COALESCE(v_detected_country, 'GN'),
    NOW(), NOW()
  )
  ON CONFLICT (user_id) DO NOTHING;

  -- ── 3. Créer la carte virtuelle ───────────────────────────────
  card_number := '5224' || LPAD((RANDOM() * 999999999999)::BIGINT::TEXT, 12, '0');

  INSERT INTO public.virtual_cards (
    user_id, card_number, holder_name, expiry_date, cvv, status,
    daily_limit, monthly_limit
  )
  VALUES (
    NEW.id,
    card_number,
    COALESCE(
      NULLIF(TRIM(
        COALESCE((NEW.raw_user_meta_data::jsonb)->>'first_name', '') || ' ' ||
        COALESCE((NEW.raw_user_meta_data::jsonb)->>'last_name',  '')
      ), ''),
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
  RAISE LOG 'Error in handle_new_user for user %: %', NEW.id, SQLERRM;
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

-- ─────────────────────────────────────────────────────────────────
-- 2. TRIGGER POST-OAUTH : corriger la devise quand geo-detect
--    met à jour detected_country sur un wallet encore en GNF/vide
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync_wallet_currency_on_country_update()
RETURNS TRIGGER AS $$
DECLARE
  v_currency    TEXT;
  v_wallet_id   BIGINT;
  v_balance     NUMERIC;
  v_locked      BOOLEAN;
  v_lock_reason TEXT;
BEGIN
  -- Déclencher seulement si detected_country vient d'être défini
  IF NEW.detected_country IS NULL
    OR NEW.detected_country = OLD.detected_country
  THEN
    RETURN NEW;
  END IF;

  -- Lire le wallet de l'utilisateur
  SELECT id, balance, currency_locked, currency_lock_reason
  INTO v_wallet_id, v_balance, v_locked, v_lock_reason
  FROM wallets
  WHERE user_id = NEW.id
  ORDER BY updated_at DESC
  LIMIT 1;

  IF v_wallet_id IS NULL THEN
    RETURN NEW; -- Pas de wallet, le trigger de création s'en chargera
  END IF;

  -- Ne pas toucher aux wallets verrouillés par le PDG
  IF v_locked = true
    AND v_lock_reason IS NOT NULL
    AND v_lock_reason LIKE '%PDG%'
  THEN
    RETURN NEW;
  END IF;

  -- Seulement corriger si le wallet est encore à GNF par défaut et vide
  IF v_balance > 0 THEN
    RETURN NEW;
  END IF;

  -- Déterminer la bonne devise
  v_currency := COALESCE(
    NULLIF(NEW.detected_currency, ''),
    get_currency_for_country(NEW.detected_country),
    'GNF'
  );

  -- Ne rien faire si la devise est déjà correcte
  IF (SELECT currency FROM wallets WHERE id = v_wallet_id) = v_currency THEN
    -- Juste s'assurer que le wallet est verrouillé
    UPDATE wallets
    SET currency_locked      = true,
        currency_locked_at   = COALESCE(currency_locked_at, NOW()),
        currency_lock_reason = COALESCE(
          currency_lock_reason,
          'Devise confirmée après géo-détection: ' || NEW.detected_country
        ),
        updated_at = NOW()
    WHERE id = v_wallet_id AND (currency_locked IS NOT TRUE);
    RETURN NEW;
  END IF;

  -- Mettre à jour la devise avec la bonne valeur
  UPDATE wallets
  SET currency             = v_currency,
      currency_locked      = true,
      currency_locked_at   = NOW(),
      currency_lock_reason = 'Devise corrigée après géo-détection post-inscription: '
                              || NEW.detected_country,
      updated_at           = NOW()
  WHERE id = v_wallet_id;

  RAISE LOG '[sync_wallet_currency] User %, wallet %, currency GNF → %',
    NEW.id, v_wallet_id, v_currency;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trigger_sync_wallet_on_country ON profiles;
CREATE TRIGGER trigger_sync_wallet_on_country
  AFTER UPDATE OF detected_country ON profiles
  FOR EACH ROW
  EXECUTE FUNCTION sync_wallet_currency_on_country_update();
