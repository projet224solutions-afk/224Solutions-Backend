-- ============================================================================
-- 224Guard — schéma complet (Lot C). Tables + RLS (admin/PDG only) + vue dashboard.
-- ----------------------------------------------------------------------------
-- SÉCURITÉ : aucune alerte ne contient de valeur de clé en clair (seulement hash +
-- masque). Lecture réservée aux admins/PDG (RLS). Écriture = service_role uniquement
-- (le backend ingère via /api/v2/guard224/alert) → pas d'écriture directe client.
-- Rejouable.
-- ============================================================================

-- ── Alertes ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.guard_224_alerts (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id     text,                       -- id généré côté client (dédup)
  type          text NOT NULL,
  severity      text NOT NULL,              -- CRITICAL|HIGH|MEDIUM|LOW
  pattern_key   text NOT NULL,
  label         text,
  key_hash      text,                       -- SHA-256, JAMAIS la valeur
  masked        text,                       -- masque non reconstructible
  sources       jsonb DEFAULT '[]'::jsonb,
  locations     jsonb DEFAULT '[]'::jsonb,
  score         jsonb,
  count         integer DEFAULT 1,
  status        text NOT NULL DEFAULT 'OPEN', -- OPEN|ACK|RESOLVED|FALSE_POSITIVE
  reporter_id   uuid,                        -- session ayant détecté (auth.users)
  user_agent    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_guard224_alerts_status_created ON public.guard_224_alerts (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_guard224_alerts_severity ON public.guard_224_alerts (severity);
CREATE INDEX IF NOT EXISTS idx_guard224_alerts_key_hash ON public.guard_224_alerts (key_hash);

-- ── Apprentissage adaptatif (faux positifs) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.guard_224_trust_scores (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pattern_key        text UNIQUE NOT NULL,
  false_positives    integer DEFAULT 0,
  true_positives     integer DEFAULT 0,
  adjusted_threshold double precision DEFAULT 0.5,
  updated_at         timestamptz DEFAULT now()
);

-- ── Journal de santé des composants ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.guard_224_health_log (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  component     text NOT NULL,
  status        text NOT NULL,
  failure_count integer DEFAULT 0,
  healed_at     timestamptz,
  created_at    timestamptz DEFAULT now()
);

-- ── Tentatives de tamper ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.guard_224_tamper_attempts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type        text NOT NULL,
  details     jsonb,
  ip          text,
  session_id  text,
  reporter_id uuid,
  created_at  timestamptz DEFAULT now()
);

-- ── Stats quotidiennes (score de risque) ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.guard_224_stats (
  date       date PRIMARY KEY DEFAULT current_date,
  risk_score integer DEFAULT 0,
  updated_at timestamptz DEFAULT now()
);

-- ── RLS : lecture admins/PDG, écriture service_role uniquement ──────────────
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['guard_224_alerts','guard_224_trust_scores','guard_224_health_log','guard_224_tamper_attempts','guard_224_stats']
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    -- Lecture admin/PDG (la fonction is_admin_or_pdg existe déjà dans le schéma).
    EXECUTE format($p$DROP POLICY IF EXISTS "%1$s_admin_read" ON public.%1$I$p$, t);
    EXECUTE format($p$CREATE POLICY "%1$s_admin_read" ON public.%1$I FOR SELECT TO authenticated USING (public.is_admin_or_pdg())$p$, t);
  END LOOP;
END $$;

-- Mise à jour du statut d'une alerte par un admin (ACK/RESOLVED).
DROP POLICY IF EXISTS "guard_224_alerts_admin_update" ON public.guard_224_alerts;
CREATE POLICY "guard_224_alerts_admin_update" ON public.guard_224_alerts
  FOR UPDATE TO authenticated USING (public.is_admin_or_pdg()) WITH CHECK (public.is_admin_or_pdg());

-- ── Vue synthèse dashboard ──────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.guard_224_dashboard_summary
WITH (security_invoker = true) AS
SELECT
  COUNT(*) FILTER (WHERE status = 'OPEN')                                            AS open_alerts,
  COUNT(*) FILTER (WHERE severity = 'CRITICAL' AND status = 'OPEN')                  AS critical_open,
  COUNT(*) FILTER (WHERE created_at > now() - interval '1 hour')                     AS alerts_last_hour,
  COUNT(*) FILTER (WHERE created_at > now() - interval '24 hours')                   AS alerts_last_day,
  MAX(created_at)                                                                    AS last_alert_at,
  (SELECT risk_score FROM public.guard_224_stats ORDER BY date DESC LIMIT 1)         AS current_risk_score
FROM public.guard_224_alerts;

SELECT '224Guard schéma créé (alerts/trust/health/tamper/stats + RLS admin + vue dashboard).' AS status;
