-- ============================================================================
-- CRÉATION auth_otp_codes — table OTP unifiée (flux téléphone + MFA agent/bureau)
-- ============================================================================
-- CONTEXTE (audit 16/07/2026) : 7 edge functions lisent/écrivent auth_otp_codes
-- (phone-signup-send, phone-signup-verify, phone-send-otp, phone-verify-otp,
-- auth-agent-login, auth-bureau-login, auth-verify-otp) mais la table N'EXISTE
-- PAS en prod (PGRST205) : les 2 anciennes migrations (20251130_auth_otp_codes,
-- 20251201000002_auth_otp_system) n'ont jamais été appliquées et définissent des
-- schémas contradictoires (CHECK limité à agent/bureau, otp_hash NOT NULL…)
-- incompatibles avec le code actuel. Conséquence : inscription par téléphone,
-- réinitialisation par téléphone et login OTP répondent HTTP 500.
--
-- Ce fichier crée la table au CONTRAT RÉEL du code (colonnes effectivement
-- utilisées par les 7 fonctions). user_type observés : agent, bureau, member,
-- syndicat, phone_login, phone_signup — PAS de CHECK restrictif (leçon des
-- pièges CHECK×code : table backend-only, writers de confiance uniquement).

CREATE TABLE IF NOT EXISTS public.auth_otp_codes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_type TEXT NOT NULL,
  -- Placeholder 00000000-0000-0000-0000-000000000000 utilisé à l'inscription
  -- téléphone (l'utilisateur n'existe pas encore) → PAS de FK vers auth.users.
  user_id UUID NOT NULL,
  identifier TEXT NOT NULL, -- email ou téléphone E.164
  otp_code TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  verified BOOLEAN NOT NULL DEFAULT FALSE,
  verified_at TIMESTAMPTZ,
  attempts INT NOT NULL DEFAULT 0,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Chemin de lecture des 7 fonctions : (identifier, user_type, verified).
CREATE INDEX IF NOT EXISTS idx_auth_otp_lookup ON public.auth_otp_codes(identifier, user_type, verified);
CREATE INDEX IF NOT EXISTS idx_auth_otp_expires ON public.auth_otp_codes(expires_at);

-- Backend-only : aucun accès client. RLS activé sans policy anon/authenticated
-- (deny-all) + REVOKE des privilèges. service_role (edge functions) seul accès.
ALTER TABLE public.auth_otp_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.auth_otp_codes FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.auth_otp_codes TO service_role;

-- Purge des OTP expirés depuis plus d'une heure (à appeler par un job backend).
CREATE OR REPLACE FUNCTION public.clean_expired_otp_codes()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.auth_otp_codes WHERE expires_at < NOW() - INTERVAL '1 hour';
END;
$$;
REVOKE ALL ON FUNCTION public.clean_expired_otp_codes() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.clean_expired_otp_codes() TO service_role;

COMMENT ON TABLE public.auth_otp_codes IS
  'Codes OTP — inscription/reset/login par téléphone + MFA agent/bureau. Backend-only (service_role via edge functions).';

-- Rafraîchir le cache de schéma PostgREST immédiatement.
NOTIFY pgrst, 'reload schema';
