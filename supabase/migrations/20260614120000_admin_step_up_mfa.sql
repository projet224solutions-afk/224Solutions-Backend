-- ============================================================================
-- 2FA ADMIN — Step-up TOTP VÉRIFIÉ CÔTÉ SERVEUR (ops financières sensibles)
-- ----------------------------------------------------------------------------
-- POURQUOI : l'ancien 2FA (user_2fa_settings + useTwoFactorAuth) vérifiait le code
-- TOTP DANS LE NAVIGATEUR (déchiffrement + comparaison côté client) → contournable
-- en appelant l'API directement = sécurité nulle ("cosmétique"). De plus son calcul
-- TOTP était incompatible RFC 6238 (secret Base32 traité en UTF-8) et le secret était
-- "chiffré" avec l'UUID public de l'utilisateur.
--
-- ICI : le secret TOTP vit dans une table ISOLÉE, accessible UNIQUEMENT par le backend
-- (service_role) — RLS activée SANS aucune policy → anon/authenticated = 0 accès, le
-- secret ne peut JAMAIS fuir au client. La vérification se fait côté serveur (speakeasy).
-- Append-only audité. Rejouable.
-- ============================================================================

-- ── Secret TOTP serveur (1 ligne par admin) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.admin_mfa (
  user_id           uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  secret_encrypted  text NOT NULL,              -- AES-256-GCM (clé serveur), jamais en clair
  enabled           boolean NOT NULL DEFAULT false,
  enrolled_at       timestamptz,
  last_step_up_at   timestamptz,
  failed_attempts   int NOT NULL DEFAULT 0,
  locked_until      timestamptz,                -- anti brute-force (lockout temporaire)
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- RLS activée, AUCUNE policy → seul service_role (backend) y accède (bypass RLS).
ALTER TABLE public.admin_mfa ENABLE ROW LEVEL SECURITY;
-- Verrou explicite : aucun privilège pour les rôles clients.
REVOKE ALL ON public.admin_mfa FROM anon, authenticated;

-- ── Journal d'audit append-only (enroll / activate / step-up / disable / fail) ──
CREATE TABLE IF NOT EXISTS public.admin_mfa_events (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid NOT NULL,
  event_type  text NOT NULL,        -- 'enroll' | 'activate' | 'step_up' | 'disable' | 'fail' | 'lockout'
  success     boolean NOT NULL DEFAULT true,
  ip          text,
  user_agent  text,
  details     jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_admin_mfa_events_user_created
  ON public.admin_mfa_events (user_id, created_at DESC);

ALTER TABLE public.admin_mfa_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admin_mfa_events FROM anon, authenticated;

-- Immuabilité : aucune modif/suppression, même par service_role (audit financier).
CREATE OR REPLACE FUNCTION public.prevent_admin_mfa_event_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'admin_mfa_events est append-only (audit immuable)';
END;
$$;

DROP TRIGGER IF EXISTS trg_admin_mfa_events_no_update ON public.admin_mfa_events;
CREATE TRIGGER trg_admin_mfa_events_no_update
  BEFORE UPDATE OR DELETE ON public.admin_mfa_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_admin_mfa_event_mutation();

-- Maj automatique de updated_at sur admin_mfa (réutilise le helper standard s'il existe).
DROP TRIGGER IF EXISTS trg_admin_mfa_updated_at ON public.admin_mfa;
CREATE TRIGGER trg_admin_mfa_updated_at
  BEFORE UPDATE ON public.admin_mfa
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

SELECT 'admin_mfa + admin_mfa_events créées (step-up TOTP serveur, secret isolé service_role).' AS status;
