-- =====================================================================
-- DURCISSEMENT DU SYSTÈME D'IDENTIFIANTS
-- =====================================================================
-- Les colonnes d'identité (profiles.public_id, user_ids.custom_id,
-- vendors.vendor_code) ne doivent JAMAIS être écrites depuis le navigateur.
-- Autorisé : backend (service_role) et fonctions système SECURITY DEFINER
-- (trigger d'inscription handle_new_user, RPC reorganize_user_ids_from_db…).
-- Bloqué : écritures directes par les rôles clients ('authenticated', 'anon').
--
-- Mécanisme : triggers de garde en SECURITY INVOKER qui testent current_user.
--   - Écriture directe d'un client    → current_user = 'authenticated'/'anon' → BLOQUÉ
--   - Fonction SECURITY DEFINER (postgres) → current_user = 'postgres'        → autorisé
--   - Backend service_role             → current_user = 'service_role'        → autorisé
-- (Donc reorganize_user_ids_from_db et l'inscription continuent de fonctionner.)
--
-- ⚠️ PRÉREQUIS : toute écriture d'identité côté client doit d'abord passer par
-- le backend. Migré : IdAuditManager, UserIdDisplay. À migrer AVANT d'appliquer
-- ce SQL si encore en écriture directe : IdNormalizationAudit.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 1) profiles.public_id : modification interdite côté client
CREATE OR REPLACE FUNCTION public.guard_profiles_public_id()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.public_id IS DISTINCT FROM OLD.public_id
     AND current_user IN ('authenticated', 'anon') THEN
    RAISE EXCEPTION 'public_id est en lecture seule (réservé au système)';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_guard_profiles_public_id ON public.profiles;
CREATE TRIGGER trg_guard_profiles_public_id
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_profiles_public_id();

-- 2) user_ids : aucune écriture client (insert/update/delete)
CREATE OR REPLACE FUNCTION public.guard_user_ids_write()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('authenticated', 'anon') THEN
    RAISE EXCEPTION 'Écriture sur user_ids réservée au système';
  END IF;
  RETURN COALESCE(NEW, OLD);
END $$;

DROP TRIGGER IF EXISTS trg_guard_user_ids_write ON public.user_ids;
CREATE TRIGGER trg_guard_user_ids_write
  BEFORE INSERT OR UPDATE OR DELETE ON public.user_ids
  FOR EACH ROW EXECUTE FUNCTION public.guard_user_ids_write();

-- 3) vendors.vendor_code : modification interdite côté client
CREATE OR REPLACE FUNCTION public.guard_vendors_vendor_code()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.vendor_code IS DISTINCT FROM OLD.vendor_code
     AND current_user IN ('authenticated', 'anon') THEN
    RAISE EXCEPTION 'vendor_code est en lecture seule (réservé au système)';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_guard_vendors_vendor_code ON public.vendors;
CREATE TRIGGER trg_guard_vendors_vendor_code
  BEFORE UPDATE ON public.vendors
  FOR EACH ROW EXECUTE FUNCTION public.guard_vendors_vendor_code();

-- 4) Unicité de vendor_code (en plus de public_id déjà UNIQUE)
CREATE UNIQUE INDEX IF NOT EXISTS idx_vendors_vendor_code_unique
  ON public.vendors (vendor_code) WHERE vendor_code IS NOT NULL;
