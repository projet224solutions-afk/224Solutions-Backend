-- 20260722180000_sms_routing_and_log.sql
-- PASSERELLE SMS — routage par pays CONFIGURABLE + journal de délivrabilité/coût.
--
-- Règle universelle (décision PDG) : toute authentification par téléphone passe par NOTRE
-- passerelle ; le fournisseur qui achemine est une DÉCISION DE CONFIGURATION, jamais de code.
-- Ajouter un pays = INSÉRER UNE LIGNE ici (aucun redéploiement). Ajouter un fournisseur =
-- 1 fichier implémentant SmsProvider (backend/src/services/sms/smsGateway.ts) + ses env vars.

-- ── 1) Table de routage : pays (ISO-2) → ORDRE de priorité des fournisseurs ─────────
--    '*' = ligne par défaut (tout indicatif non listé). costs = coût unitaire configuré
--    par fournisseur (jsonb, ex {"orange":150,"twilio":500}) pour le suivi de facture.
CREATE TABLE IF NOT EXISTS public.sms_country_routing (
  country_iso    text PRIMARY KEY CHECK (country_iso = '*' OR country_iso ~ '^[A-Z]{2}$'),
  provider_order text[] NOT NULL DEFAULT ARRAY['orange','twilio','edge'],
  costs          jsonb  NOT NULL DEFAULT '{}'::jsonb,
  is_active      boolean NOT NULL DEFAULT true,
  note           text,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid
);

INSERT INTO public.sms_country_routing (country_iso, provider_order, costs, note) VALUES
  ('*',  ARRAY['orange','twilio','edge'], '{}'::jsonb, 'Ordre par défaut (tout pays non listé)'),
  ('GN', ARRAY['orange','twilio','edge'], '{"orange":150}'::jsonb, 'Guinée : Orange local prioritaire (~150 GNF/SMS)')
ON CONFLICT (country_iso) DO NOTHING;

ALTER TABLE public.sms_country_routing ENABLE ROW LEVEL SECURITY;
-- Backend-only (service_role) : aucune policy → lecture/écriture via les routes PDG uniquement.

-- ── 2) Journal d'envoi : chaque tentative tracée (fournisseur, pays, latence, coût) ──
--    to_masked = numéro anonymisé (jamais le E.164 complet) ; to_hash = sha256 pour le
--    rate-limit par numéro (3 demandes / 15 min) sans stocker le numéro en clair.
CREATE TABLE IF NOT EXISTS public.sms_send_log (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usage_type  text NOT NULL DEFAULT 'other',   -- signup | reset | agent_cash | test | campaign | notification | other
  country_iso text,
  provider    text NOT NULL,
  to_masked   text,
  to_hash     text,
  success     boolean NOT NULL,
  error       text,
  latency_ms  integer,
  cost        numeric,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sms_send_log_created ON public.sms_send_log (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sms_send_log_hash    ON public.sms_send_log (to_hash, usage_type, created_at DESC);

ALTER TABLE public.sms_send_log ENABLE ROW LEVEL SECURITY;
-- Backend-only également (stats servies par les routes PDG).
