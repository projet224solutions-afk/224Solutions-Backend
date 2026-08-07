-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME FONCTIONNALITÉS — VAGUE 2 (socle) : le manifeste EN BASE, le registre des
-- sondes, les incidents avec VERDICT structuré (cascade 8.2), et l'inventaire des
-- fonctionnalités récemment mémorisées (8.6.4).
-- Le manifeste vit en FICHIERS versionnés (feature-manifest/*.json, vérité du code,
-- gardé par la CI) et est CHARGÉ ici au déploiement (fatome_manifest_upsert).
-- Blindage : RLS PDG-read sur chaque table, écriture service_role, idempotence
-- (clés naturelles + ON CONFLICT), append-only sur les incidents (résolution = champ).
-- AUCUNE écriture sur un flux d'argent. Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) MANIFESTE DES FONCTIONNALITÉS (8.4) ──────────────────────────────────
CREATE TABLE IF NOT EXISTS public.fatome_feature_manifest (
  feature_key   text PRIMARY KEY,
  interface     text NOT NULL,
  label         text NOT NULL,
  criticality   text NOT NULL DEFAULT 'normal' CHECK (criticality IN ('critical','high','normal')),
  routes        jsonb NOT NULL DEFAULT '[]'::jsonb,   -- ["POST /api/orders", …]
  rpcs          jsonb NOT NULL DEFAULT '[]'::jsonb,   -- ["create_order_core", …]
  tables        jsonb NOT NULL DEFAULT '[]'::jsonb,
  externals     jsonb NOT NULL DEFAULT '[]'::jsonb,   -- ["stripe","agora",…]
  invariants    jsonb NOT NULL DEFAULT '[]'::jsonb,   -- règles métier vérifiables (texte + check)
  depends_on    jsonb NOT NULL DEFAULT '[]'::jsonb,   -- graphe amont
  sources       jsonb NOT NULL DEFAULT '[]'::jsonb,   -- fichiers cités (traçabilité)
  added_at      timestamptz NOT NULL DEFAULT now(),
  added_commit  text,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ffm_interface ON public.fatome_feature_manifest (interface);
ALTER TABLE public.fatome_feature_manifest ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ffm_read_pdg ON public.fatome_feature_manifest;
CREATE POLICY ffm_read_pdg ON public.fatome_feature_manifest FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- Chargement idempotent depuis les fichiers versionnés (appelé au boot du leader).
-- added_at/added_commit ne sont JAMAIS écrasés (la mémoire est datée — 8.6.4).
CREATE OR REPLACE FUNCTION public.fatome_manifest_upsert(p_entries jsonb, p_commit text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_e jsonb; v_ins int := 0; v_upd int := 0; v_new boolean;
BEGIN
  FOR v_e IN SELECT * FROM jsonb_array_elements(COALESCE(p_entries, '[]'::jsonb)) LOOP
    SELECT NOT EXISTS (SELECT 1 FROM public.fatome_feature_manifest
      WHERE feature_key = v_e->>'feature_key') INTO v_new;
    INSERT INTO public.fatome_feature_manifest AS m (
      feature_key, interface, label, criticality, routes, rpcs, tables, externals,
      invariants, depends_on, sources, added_commit)
    VALUES (
      v_e->>'feature_key', v_e->>'interface', v_e->>'label',
      COALESCE(v_e->>'criticality','normal'),
      COALESCE(v_e->'routes','[]'::jsonb), COALESCE(v_e->'rpcs','[]'::jsonb),
      COALESCE(v_e->'tables','[]'::jsonb), COALESCE(v_e->'externals','[]'::jsonb),
      COALESCE(v_e->'invariants','[]'::jsonb), COALESCE(v_e->'depends_on','[]'::jsonb),
      COALESCE(v_e->'sources','[]'::jsonb), p_commit)
    ON CONFLICT (feature_key) DO UPDATE SET
      interface = EXCLUDED.interface, label = EXCLUDED.label, criticality = EXCLUDED.criticality,
      routes = EXCLUDED.routes, rpcs = EXCLUDED.rpcs, tables = EXCLUDED.tables,
      externals = EXCLUDED.externals, invariants = EXCLUDED.invariants,
      depends_on = EXCLUDED.depends_on, sources = EXCLUDED.sources, updated_at = now();
    IF v_new THEN v_ins := v_ins + 1; ELSE v_upd := v_upd + 1; END IF;
  END LOOP;
  RETURN jsonb_build_object('inserted', v_ins, 'updated', v_upd,
    'total', (SELECT count(*) FROM public.fatome_feature_manifest));
END; $$;
REVOKE ALL ON FUNCTION public.fatome_manifest_upsert(jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_manifest_upsert(jsonb, text) TO service_role;

-- ── 2) REGISTRE DES SONDES (8.1) ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.fatome_feature_probes (
  probe_key    text PRIMARY KEY,
  feature_key  text NOT NULL REFERENCES public.fatome_feature_manifest(feature_key) ON DELETE CASCADE,
  probe_kind   text NOT NULL DEFAULT 'availability'
                 CHECK (probe_kind IN ('availability','invariant','external','canary')),
  label        text NOT NULL,
  config       jsonb NOT NULL DEFAULT '{}'::jsonb,   -- ex. {"rpc":"...","args":{},"expect":"rows>0"}
  criticality  text NOT NULL DEFAULT 'normal' CHECK (criticality IN ('critical','high','normal')),
  enabled      boolean NOT NULL DEFAULT true,
  is_default   boolean NOT NULL DEFAULT false,       -- sonde générée par défaut (badge PDG, 8.6.2)
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ffp_feature ON public.fatome_feature_probes (feature_key);
ALTER TABLE public.fatome_feature_probes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ffp_read_pdg ON public.fatome_feature_probes;
CREATE POLICY ffp_read_pdg ON public.fatome_feature_probes FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- Résultats des sondes (append-only, purge 30 j par cron) — base de l'uptime 7 j.
CREATE TABLE IF NOT EXISTS public.fatome_probe_runs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  probe_key   text NOT NULL,
  feature_key text NOT NULL,
  run_at      timestamptz NOT NULL DEFAULT now(),
  ok          boolean NOT NULL,
  duration_ms int,
  layer       text,          -- couche en défaut (cascade 8.2) : route|rpc|data|external|frontend_api
  error_code  text,          -- SQLSTATE / HTTP / code externe
  message     text
);
CREATE INDEX IF NOT EXISTS idx_fpr_feature_run ON public.fatome_probe_runs (feature_key, run_at DESC);
ALTER TABLE public.fatome_probe_runs ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fpr_read_pdg ON public.fatome_probe_runs;
CREATE POLICY fpr_read_pdg ON public.fatome_probe_runs FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- ── 3) INCIDENTS avec VERDICT structuré (cascade 8.2) ───────────────────────
CREATE TABLE IF NOT EXISTS public.fatome_feature_incidents (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  feature_key   text NOT NULL,
  signature     text NOT NULL,          -- feature|layer|cause_code (mémoire des incidents, 8.5.4)
  layer         text,
  cause_code    text,
  cause_label   text,
  suspect_event text,                   -- « migration de 14:30 », « déploiement abc123 »
  impact        text,
  detail        jsonb,
  ai_diagnosis  jsonb,                  -- rempli en vague 3 (cerveau IA)
  started_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at   timestamptz,
  resolution    text,
  UNIQUE (feature_key, signature, started_at)
);
CREATE INDEX IF NOT EXISTS idx_ffi_open ON public.fatome_feature_incidents (feature_key)
  WHERE resolved_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_ffi_sig ON public.fatome_feature_incidents (signature, started_at DESC);
ALTER TABLE public.fatome_feature_incidents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ffi_read_pdg ON public.fatome_feature_incidents;
CREATE POLICY ffi_read_pdg ON public.fatome_feature_incidents FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- Ouvre OU prolonge un incident (idempotent par signature ouverte) + anomalie Fatome.
CREATE OR REPLACE FUNCTION public.fatome_incident_open(
  p_feature text, p_signature text, p_layer text, p_cause_code text, p_cause_label text,
  p_suspect text, p_impact text, p_detail jsonb DEFAULT '{}'::jsonb, p_severity text DEFAULT 'high')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id bigint; v_new boolean := false; v_day text := to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD');
BEGIN
  UPDATE public.fatome_feature_incidents
  SET last_seen_at = now(), detail = COALESCE(p_detail, detail)
  WHERE feature_key = p_feature AND signature = p_signature AND resolved_at IS NULL
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    INSERT INTO public.fatome_feature_incidents (
      feature_key, signature, layer, cause_code, cause_label, suspect_event, impact, detail)
    VALUES (p_feature, p_signature, p_layer, p_cause_code, p_cause_label, p_suspect, p_impact, p_detail)
    RETURNING id INTO v_id;
    v_new := true;
  END IF;

  PERFORM public.fatome_raise('feature:' || p_feature,
    'incident:' || p_feature || ':' || p_signature || ':' || v_day,
    COALESCE(p_severity,'high'),
    jsonb_build_object('incident_id', v_id, 'layer', p_layer, 'cause', p_cause_label,
      'suspect', p_suspect, 'impact', p_impact));

  RETURN jsonb_build_object('incident_id', v_id, 'new', v_new);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_incident_open(text, text, text, text, text, text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_incident_open(text, text, text, text, text, text, text, jsonb, text) TO service_role;

CREATE OR REPLACE FUNCTION public.fatome_incident_resolve(p_feature text, p_resolution text DEFAULT 'probe_ok')
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.fatome_feature_incidents
  SET resolved_at = now(), resolution = COALESCE(p_resolution,'probe_ok')
  WHERE feature_key = p_feature AND resolved_at IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n > 0 THEN PERFORM public.fatome_resolve_type('feature:' || p_feature); END IF;
  RETURN v_n;
END; $$;
REVOKE ALL ON FUNCTION public.fatome_incident_resolve(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_incident_resolve(text, text) TO service_role;

-- Incidents PASSÉS de même signature (la MÉMOIRE — nourrit le dossier IA en vague 3).
CREATE OR REPLACE FUNCTION public.fatome_similar_incidents(p_signature text, p_limit int DEFAULT 3)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (
    SELECT id, feature_key, cause_label, suspect_event, started_at, resolved_at, resolution
    FROM public.fatome_feature_incidents
    WHERE signature = p_signature AND resolved_at IS NOT NULL
    ORDER BY resolved_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit,3),1),10)) x), '[]'::jsonb);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_similar_incidents(text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_similar_incidents(text, int) TO authenticated, service_role;

-- ── 4) CORRÉLATION TEMPORELLE (8.2.3) : migrations et déploiements récents ───
-- Le « suspect n°1 » : dernière migration appliquée avant l'heure de la panne.
CREATE OR REPLACE FUNCTION public.fatome_recent_changes(p_since interval DEFAULT interval '6 hours')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_migrations jsonb := '[]'::jsonb;
BEGIN
  BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_migrations FROM (
      SELECT version, name FROM supabase_migrations.schema_migrations
      ORDER BY version DESC LIMIT 5) x;
  EXCEPTION WHEN OTHERS THEN v_migrations := '[]'::jsonb; END;
  RETURN jsonb_build_object('recent_migrations', v_migrations, 'window', p_since::text);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_recent_changes(interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_recent_changes(interval) TO authenticated, service_role;

-- ── 5) LECTURES PDG (onglet Fonctionnalités + carte santé) ──────────────────
-- Santé par fonctionnalité : dernier run, uptime 7 j, incident ouvert, badge sonde par défaut.
CREATE OR REPLACE FUNCTION public.fatome_features_health()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.interface, x.feature_key) FROM (
    SELECT m.feature_key, m.interface, m.label, m.criticality, m.added_at,
      (m.added_at > now() - interval '7 days') AS is_new,
      (SELECT count(*) FROM public.fatome_feature_probes p
         WHERE p.feature_key = m.feature_key AND p.enabled) AS probes,
      (SELECT bool_and(p.is_default) FROM public.fatome_feature_probes p
         WHERE p.feature_key = m.feature_key AND p.enabled) AS only_default_probes,
      (SELECT jsonb_build_object('ok', r.ok, 'at', r.run_at, 'layer', r.layer, 'msg', r.message)
         FROM public.fatome_probe_runs r WHERE r.feature_key = m.feature_key
         ORDER BY r.run_at DESC LIMIT 1) AS last_run,
      (SELECT round(100.0 * count(*) FILTER (WHERE r.ok) / NULLIF(count(*),0), 1)
         FROM public.fatome_probe_runs r
         WHERE r.feature_key = m.feature_key AND r.run_at > now() - interval '7 days') AS uptime_7d,
      (SELECT jsonb_build_object('id', i.id, 'layer', i.layer, 'cause', i.cause_label,
              'suspect', i.suspect_event, 'impact', i.impact, 'since', i.started_at,
              'ai', i.ai_diagnosis)
         FROM public.fatome_feature_incidents i
         WHERE i.feature_key = m.feature_key AND i.resolved_at IS NULL
         ORDER BY i.started_at DESC LIMIT 1) AS open_incident
    FROM public.fatome_feature_manifest m) x), '[]'::jsonb);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_features_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_features_health() TO authenticated, service_role;

-- Fiche manifeste d'UNE fonctionnalité (consultable depuis l'onglet).
CREATE OR REPLACE FUNCTION public.fatome_feature_detail(p_key text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT to_jsonb(m) INTO v FROM public.fatome_feature_manifest m WHERE m.feature_key = p_key;
  IF v IS NULL THEN RETURN jsonb_build_object('found', false); END IF;
  RETURN v || jsonb_build_object(
    'probes', COALESCE((SELECT jsonb_agg(jsonb_build_object('key', p.probe_key, 'label', p.label,
        'kind', p.probe_kind, 'default', p.is_default, 'enabled', p.enabled))
      FROM public.fatome_feature_probes p WHERE p.feature_key = p_key), '[]'::jsonb),
    'incidents', COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.started_at DESC)
      FROM (SELECT id, layer, cause_label, suspect_event, impact, started_at, resolved_at, resolution, ai_diagnosis
            FROM public.fatome_feature_incidents WHERE feature_key = p_key
            ORDER BY started_at DESC LIMIT 10) i), '[]'::jsonb));
END; $$;
REVOKE ALL ON FUNCTION public.fatome_feature_detail(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_feature_detail(text) TO authenticated, service_role;

-- ── 6) REGISTRE : le Fatome Fonctionnalités devient ACTIF (vague 2 livrée) ──
UPDATE public.fatome_registry SET enabled = true WHERE fatome_key = 'fatome_fonctionnalites';

COMMIT;

-- ── 7) PURGE des runs de sondes (rétention 30 j) ────────────────────────────
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('fatome-probe-runs-purge')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'fatome-probe-runs-purge');
    PERFORM cron.schedule('fatome-probe-runs-purge', '50 3 * * *',
      'DELETE FROM public.fatome_probe_runs WHERE run_at < now() - interval ''30 days'';');
  END IF;
END $$;
