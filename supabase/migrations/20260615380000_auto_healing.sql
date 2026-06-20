-- ============================================================================
-- AUTO-RÉPARATION SUPERVISÉE (dual-IA) — FONDATION (additif, rejouable).
-- ----------------------------------------------------------------------------
-- Chaque incident détecté par la surveillance (system_alerts) reçoit une chaîne
-- de diagnostic : OpenAI propose un correctif → Claude le vérifie/corrige.
-- La remédiation choisie est CLASSÉE (auto_safe = idempotent, ou needs_human =
-- argent/sensible). FONDATION : on enregistre + propose, on N'EXÉCUTE PAS encore.
-- RLS : aucune policy → seul le backend (service_role) lit/écrit (anon/auth bloqués).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.auto_healing_incidents (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  incident_key      text NOT NULL,                       -- dédup : module + alert_key
  source            text NOT NULL DEFAULT 'system_alert',-- system_alert | monitoring_event | runtime
  module            text,
  alert_key         text,
  severity          text,                                -- low | medium | high | critical
  title             text,
  detail            text,
  context           jsonb NOT NULL DEFAULT '{}',         -- alerte brute + suggested_fix

  -- Étape 1 — OpenAI (diagnostic + proposition)
  openai_diagnosis  text,
  openai_action     text,                                -- id d'action du registre, ou 'escalate'/'investigate'
  openai_rationale  text,

  -- Étape 2 — Claude (vérification / correction)
  claude_verdict    text,                                -- approved | revised | rejected
  claude_analysis   text,
  claude_action     text,

  -- Décision finale
  final_action      text,
  remediation_label text,
  remediation_kind  text,                                -- auto_safe | needs_human | none
  auto_apply_eligible boolean NOT NULL DEFAULT false,

  status            text NOT NULL DEFAULT 'detected',    -- detected|diagnosed|proposed|escalated|applied|resolved|failed
  applied_at        timestamptz,
  applied_by        uuid,
  apply_result      jsonb,
  acknowledged_by   uuid,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Un incident ACTIF unique par clé (on ré-ouvre une nouvelle ligne si la précédente est close).
CREATE UNIQUE INDEX IF NOT EXISTS uniq_auto_healing_open
  ON public.auto_healing_incidents (incident_key)
  WHERE status NOT IN ('resolved', 'applied', 'failed');

CREATE INDEX IF NOT EXISTS idx_auto_healing_status
  ON public.auto_healing_incidents (status, severity, created_at DESC);

ALTER TABLE public.auto_healing_incidents ENABLE ROW LEVEL SECURITY;
-- Aucune policy volontairement : seul service_role (backend) accède. anon/authenticated bloqués.

SELECT 'Auto-réparation supervisée (dual-IA) : table auto_healing_incidents (fondation).' AS status;
