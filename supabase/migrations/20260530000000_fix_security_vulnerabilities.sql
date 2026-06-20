-- ============================================================================
-- MIGRATION SÉCURITÉ : Correction des vulnérabilités critiques
-- Date: 2026-05-30
--
-- PROBLÈMES CORRIGÉS :
--   1. 'actionnaire' manquant dans user_role enum
--      → Le trigger handle_new_user convertissait silencieusement les
--        comptes actionnaire en 'client' (CAUSE RACINE des pertes de rôles)
--
--   2. GRANT trop large sur tous les tables (incluant UPDATE role sur profiles)
--      → N'importe quel utilisateur authentifié pouvait changer son propre
--        rôle ou celui d'un autre si RLS était absent
--
--   3. Aucune protection colonne sur profiles.role
--      → La colonne role n'était pas protégée contre les modifications
--        par des utilisateurs authentifiés ordinaires
--
--   4. Aucun garde-fou sur la table profiles pour empêcher la corruption
--      de données critiques (role, id, email)
-- ============================================================================

-- ============================================================================
-- 1. AJOUTER 'actionnaire' À L'ENUM user_role (CORRECTION CRITIQUE)
-- ============================================================================
-- Sans cela, toute création de compte actionnaire déclenche une exception
-- dans handle_new_user qui silencieusement définit le rôle à 'client'

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_enum
    WHERE enumlabel = 'actionnaire'
      AND enumtypid = (SELECT oid FROM pg_type WHERE typname = 'user_role')
  ) THEN
    ALTER TYPE public.user_role ADD VALUE 'actionnaire';
    RAISE NOTICE 'Valeur actionnaire ajoutée à user_role enum';
  ELSE
    RAISE NOTICE 'actionnaire existe déjà dans user_role enum';
  END IF;
END $$;

-- ============================================================================
-- 2. PROTÉGER LA COLONNE profiles.role VIA PERMISSIONS COLONNE
-- ============================================================================
-- Les utilisateurs authentifiés peuvent mettre à jour leur profil
-- SAUF les colonnes critiques : role, id
-- Seul service_role (backend) peut modifier le rôle

-- Révoquer UPDATE général sur profiles pour les utilisateurs authentifiés
REVOKE UPDATE ON public.profiles FROM authenticated;

-- Ré-octroyer UPDATE uniquement sur les colonnes non-critiques
GRANT UPDATE (
  first_name,
  last_name,
  phone,
  avatar_url,
  country,
  detected_country,
  detected_currency,
  bio,
  date_of_birth,
  address,
  city,
  postal_code,
  language_preference,
  notification_preferences,
  is_active,
  updated_at
) ON public.profiles TO authenticated;

-- ============================================================================
-- 3. TRIGGER GARDE-FOU SUR profiles (ceinture + bretelles)
-- ============================================================================
-- Même si quelqu'un contourne les permissions colonne, ce trigger
-- annule silencieusement tout changement de rôle fait par un utilisateur
-- authentifié ordinaire (non service_role)

CREATE OR REPLACE FUNCTION public.guard_profile_critical_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Protéger le champ role : seul service_role peut le modifier
  IF OLD.role IS DISTINCT FROM NEW.role THEN
    IF auth.role() = 'authenticated' THEN
      -- Annuler le changement de rôle silencieusement (garder l'ancien)
      NEW.role := OLD.role;
      RAISE LOG '[guard_profile] Tentative de modification du rôle bloquée. user_id=%, ancien_role=%, nouveau_role_tenté=%',
        OLD.id, OLD.role, NEW.role;
    END IF;
  END IF;

  -- Protéger l'email : jamais modifiable par authenticated (seulement service_role)
  IF OLD.email IS DISTINCT FROM NEW.email THEN
    IF auth.role() = 'authenticated' THEN
      NEW.email := OLD.email;
      RAISE LOG '[guard_profile] Tentative de modification email bloquée. user_id=%', OLD.id;
    END IF;
  END IF;

  -- Protéger l'ID : jamais modifiable (personne)
  IF OLD.id IS DISTINCT FROM NEW.id THEN
    NEW.id := OLD.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS guard_profile_critical_fields_trigger ON public.profiles;
CREATE TRIGGER guard_profile_critical_fields_trigger
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_profile_critical_fields();

-- ============================================================================
-- 4. CORRIGER LE GRANT TROP LARGE (RÉÉQUILIBRAGE)
-- ============================================================================
-- Le GRANT DELETE sur ALL TABLES est dangereux.
-- On révoque DELETE pour authenticated sur les tables critiques.
-- Les suppressions légitimes passent par le backend (service_role).

REVOKE DELETE ON public.profiles FROM authenticated;
REVOKE DELETE ON public.wallets FROM authenticated;
REVOKE DELETE ON public.wallet_transactions FROM authenticated;
REVOKE DELETE ON public.vendors FROM authenticated;
REVOKE DELETE ON public.subscriptions FROM authenticated;
REVOKE DELETE ON public.driver_subscriptions FROM authenticated;
REVOKE DELETE ON public.orders FROM authenticated;
REVOKE DELETE ON public.agents_management FROM authenticated;
REVOKE DELETE ON public.shareholders FROM authenticated;
REVOKE DELETE ON public.shareholder_assignments FROM authenticated;
REVOKE DELETE ON public.shareholder_revenues FROM authenticated;
REVOKE DELETE ON public.shareholder_payments FROM authenticated;

-- ============================================================================
-- 5. S'ASSURER QUE RLS EST ACTIVÉ SUR LES TABLES CRITIQUES
-- ============================================================================

ALTER TABLE IF EXISTS public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.shareholders ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.shareholder_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.shareholder_revenues ENABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS public.shareholder_payments ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- 6. CORRIGER handle_new_user : TRAITEMENT EXPLICITE D'ACTIONNAIRE
-- ============================================================================
-- Le trigger convertissait silencieusement 'actionnaire' → 'client'
-- car 'actionnaire' n'était pas dans l'enum. Maintenant que l'enum est corrigé,
-- on met aussi à jour le trigger pour être explicite.

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

  -- Validation explicite des rôles connus (évite la conversion silencieuse en 'client')
  IF user_role_text NOT IN (
    'client','vendeur','livreur','taxi','driver','syndicat','bureau',
    'transitaire','prestataire','pdg','admin','ceo','agent','vendor_agent',
    'actionnaire'
  ) THEN
    RAISE LOG '[handle_new_user] Rôle inconnu "%" pour user %, remplacé par client', user_role_text, NEW.id;
    user_role_text := 'client';
  END IF;

  BEGIN
    user_role_value := user_role_text::user_role;
  EXCEPTION WHEN OTHERS THEN
    RAISE LOG '[handle_new_user] Erreur cast rôle "%" pour user %: %. Fallback client.', user_role_text, NEW.id, SQLERRM;
    user_role_text  := 'client';
    user_role_value := 'client'::user_role;
  END;

  -- ── Identifiant public ────────────────────────────────────────
  generated_public_id := public.generate_unique_public_id(user_role_text);

  -- ── Pays & devise depuis les métadonnées ─────────────────────
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

  -- ── Insérer le profil ─────────────────────────────────────────
  INSERT INTO public.profiles (
    id,
    email,
    first_name,
    last_name,
    role,
    phone,
    public_id,
    country,
    detected_country,
    detected_currency,
    is_active,
    created_at,
    updated_at
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

  -- ── Créer le wallet directement ───────────────────────────────
  v_wallet_currency := COALESCE(v_detected_currency, 'GNF');

  INSERT INTO public.wallets (user_id, balance, currency, is_active)
  VALUES (NEW.id, 0, v_wallet_currency, true)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE LOG 'Error in handle_new_user for user %: %', NEW.id, SQLERRM;
  RETURN NEW;
END;
$$;

-- ============================================================================
-- 7. VÉRIFICATION : S'ASSURER QUE TOUS LES ACTIONNAIRES ONT LE BON RÔLE
-- ============================================================================
-- Corriger les profils d'actionnaires existants qui ont été créés avec
-- role='client' à cause du bug de l'enum manquant

UPDATE public.profiles p
SET role = 'actionnaire'
FROM public.shareholders s
WHERE s.user_id = p.id
  AND p.role = 'client'
  AND s.status IN ('active', 'suspended');

-- Log de l'opération
DO $$
DECLARE
  v_count INTEGER;
BEGIN
  GET DIAGNOSTICS v_count = ROW_COUNT;
  IF v_count > 0 THEN
    RAISE NOTICE '✅ % compte(s) actionnaire corrigé(s) : role client → actionnaire', v_count;
  ELSE
    RAISE NOTICE '✅ Aucun compte actionnaire avec role incorrect trouvé';
  END IF;
END $$;

-- ============================================================================
-- 8. VÉRIFICATION FINALE
-- ============================================================================

DO $$
DECLARE
  v_has_actionnaire BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM pg_enum
    WHERE enumlabel = 'actionnaire'
      AND enumtypid = (SELECT oid FROM pg_type WHERE typname = 'user_role')
  ) INTO v_has_actionnaire;

  IF v_has_actionnaire THEN
    RAISE NOTICE '✅ user_role enum contient actionnaire';
  ELSE
    RAISE EXCEPTION '❌ CRITIQUE: actionnaire toujours absent de user_role enum!';
  END IF;
END $$;
