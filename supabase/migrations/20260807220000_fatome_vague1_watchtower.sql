-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME VAGUE 1 — LA TOUR DE GARDE COMPLÈTE (sur le socle dead-man 20260807200000).
-- §4 alertes hors-bande (journal anti-spam SMS), §6 digest quotidien 07h00 Conakry (UTC),
-- §7 escalade des critiques (+6h/+24h/+48h, bandeau permanent), §9.1 contrat commun des
-- heartbeats + verdicts du Général, §9.3 pg_cron vérifie DÉSORMAIS le Général,
-- §10 RPC PDG-only paginées (alertes actives, historique filtrable, journal d'activité, ack).
-- AUCUN mécanisme ne touche un flux d'argent (lecture seule sur tout ce qui est argent).
-- Blindage : RLS PDG-read sur chaque table, écritures service_role/SECURITY DEFINER,
-- idempotence par dédup (réf datée, UNIQUE, kind+cycle), append-only (résolution = champ).
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── A) ANOMALIES : résolution TRAÇABLE (auto vs PDG) + ack PDG ───────────────
ALTER TABLE public.fatome_anomalies
  ADD COLUMN IF NOT EXISTS resolved_at timestamptz,
  ADD COLUMN IF NOT EXISTS resolved_by uuid,
  ADD COLUMN IF NOT EXISTS resolution_source text;

CREATE OR REPLACE FUNCTION public.fatome_resolve_type(p_type text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_n int;
BEGIN
  UPDATE public.fatome_anomalies
  SET resolved = true, resolved_at = COALESCE(resolved_at, now()),
      resolution_source = COALESCE(resolution_source, 'auto')
  WHERE anomaly_type = p_type AND resolved = false;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;
REVOKE ALL ON FUNCTION public.fatome_resolve_type(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_resolve_type(text) TO service_role;

-- Marquer traitée depuis l'interface PDG (idempotent, tracé created_by).
CREATE OR REPLACE FUNCTION public.fatome_anomaly_ack(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_row record;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.fatome_anomalies
  SET resolved = true, resolved_at = COALESCE(resolved_at, now()),
      resolved_by = auth.uid(), resolution_source = COALESCE(resolution_source, 'pdg')
  WHERE id = p_id AND resolved = false
  RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('success', true, 'skipped', true);
  END IF;
  RETURN jsonb_build_object('success', true, 'id', v_row.id, 'resolved_at', v_row.resolved_at);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_anomaly_ack(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_anomaly_ack(bigint) TO authenticated, service_role;

-- Deep-link des notifications d'anomalie → l'onglet Fatome (10.3).
CREATE OR REPLACE FUNCTION public.fatome_raise(p_type text, p_ref text, p_severity text, p_detail jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_new boolean := false; p record;
BEGIN
  INSERT INTO public.fatome_anomalies (anomaly_type, ref, severity, detail)
  VALUES (p_type, p_ref, coalesce(p_severity,'high'), p_detail)
  ON CONFLICT (anomaly_type, ref) DO NOTHING;
  GET DIAGNOSTICS v_new = ROW_COUNT;
  IF v_new THEN
    FOR p IN SELECT id FROM public.profiles WHERE role IN ('pdg','admin','ceo') LIMIT 5 LOOP
      BEGIN
        INSERT INTO public.notifications (user_id, title, message, type, metadata)
        VALUES (p.id, '👻 Fatome Sentinelle : anomalie détectée',
          p_type || ' — réf ' || p_ref, 'fatome_anomaly',
          jsonb_build_object('anomaly_type', p_type, 'ref', p_ref, 'link', '/pdg?tab=fatome'));
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END LOOP;
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.fatome_raise(text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_raise(text, text, text, jsonb) TO service_role;

-- ── B) CONTRAT COMMUN §9.1 : heartbeats de TOUS les Fatomes ──────────────────
CREATE TABLE IF NOT EXISTS public.fatome_heartbeats (
  fatome_key  text PRIMARY KEY REFERENCES public.fatome_registry(fatome_key),
  last_beat   timestamptz NOT NULL DEFAULT now(),
  last_ok     boolean NOT NULL DEFAULT true,
  last_error  text,
  cycle_count bigint NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.fatome_heartbeats ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fatome_hbs_read_pdg ON public.fatome_heartbeats;
CREATE POLICY fatome_hbs_read_pdg ON public.fatome_heartbeats FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());
-- Écriture : service_role uniquement (aucune policy INSERT/UPDATE).

CREATE OR REPLACE FUNCTION public.fatome_beat(p_key text, p_ok boolean, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.fatome_heartbeats (fatome_key, last_beat, last_ok, last_error, cycle_count)
  VALUES (p_key, now(), COALESCE(p_ok, true), CASE WHEN COALESCE(p_ok,true) THEN NULL ELSE p_error END, 1)
  ON CONFLICT (fatome_key) DO UPDATE
  SET last_beat = now(), last_ok = COALESCE(p_ok, true),
      last_error = CASE WHEN COALESCE(p_ok,true) THEN NULL ELSE p_error END,
      cycle_count = fatome_heartbeats.cycle_count + 1, updated_at = now();
END; $$;
REVOKE ALL ON FUNCTION public.fatome_beat(text, boolean, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_beat(text, boolean, text) TO service_role;

-- Le Général entre au registre ; « Fonctionnalités » désactivé tant que la vague 2 n'est pas livrée
-- (pas de faux MORT sur un Fatome qui n'existe pas encore).
INSERT INTO public.fatome_registry (fatome_key, label, heartbeat_source, health_check_rpc, expected_interval_sec, criticality)
VALUES ('fatome_general', 'Fatome Surveillance Générale', 'fatome_heartbeats', NULL, 300, 'critical')
ON CONFLICT (fatome_key) DO NOTHING;
UPDATE public.fatome_registry SET enabled = false
WHERE fatome_key = 'fatome_fonctionnalites';

-- ── C) VERDICTS DU GÉNÉRAL (journal append-only) ─────────────────────────────
CREATE TABLE IF NOT EXISTS public.fatome_general_checks (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_at timestamptz NOT NULL DEFAULT now(),
  fatome_key text NOT NULL,
  verdict text NOT NULL CHECK (verdict IN ('SAIN','DEGRADE','MORT','SUSPECT','INCONNU')),
  reason text,
  heartbeat_age_sec int,
  detail jsonb
);
CREATE INDEX IF NOT EXISTS idx_fgc_key_run ON public.fatome_general_checks (fatome_key, run_at DESC);
ALTER TABLE public.fatome_general_checks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fgc_read_pdg ON public.fatome_general_checks;
CREATE POLICY fgc_read_pdg ON public.fatome_general_checks FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- ── D) JOURNAL D'ACTIVITÉ §10.1.4 : ce que chaque Fatome a FAIT ──────────────
CREATE TABLE IF NOT EXISTS public.fatome_activity_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fatome_key text NOT NULL,
  run_at timestamptz NOT NULL DEFAULT now(),
  duration_ms int,
  ok boolean NOT NULL DEFAULT true,
  message text,
  volume jsonb
);
CREATE INDEX IF NOT EXISTS idx_fal_key_run ON public.fatome_activity_log (fatome_key, run_at DESC);
ALTER TABLE public.fatome_activity_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fal_read_pdg ON public.fatome_activity_log;
CREATE POLICY fal_read_pdg ON public.fatome_activity_log FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- ── E) JOURNAL DES ALERTES HORS-BANDE §4 (anti-spam SMS 6 h/type, append-only) ─
CREATE TABLE IF NOT EXISTS public.fatome_alert_dispatch (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  anomaly_type text NOT NULL,
  channel text NOT NULL DEFAULT 'sms',
  sent_to_masked text,
  sent_at timestamptz NOT NULL DEFAULT now(),
  ok boolean NOT NULL DEFAULT true,
  error text
);
CREATE INDEX IF NOT EXISTS idx_fad_type_sent ON public.fatome_alert_dispatch (anomaly_type, sent_at DESC);
ALTER TABLE public.fatome_alert_dispatch ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fad_read_pdg ON public.fatome_alert_dispatch;
CREATE POLICY fad_read_pdg ON public.fatome_alert_dispatch FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- ── F) ESCALADE §7 : une critique ignorée ne s'éteint JAMAIS ─────────────────
-- +6 h / +24 h / +48 h : ré-alerte in-app (dédup par anomalie+cycle) ; au 3e cycle le
-- bandeau permanent s'appuie sur fatome_escalation_level() (RPC lue par la section PDG).
CREATE OR REPLACE FUNCTION public.fatome_escalation_sweep()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_a record; v_cycle int; v_age interval; p record; v_raised int := 0;
BEGIN
  FOR v_a IN
    SELECT id, anomaly_type, ref, detected_at FROM public.fatome_anomalies
    WHERE severity = 'critical' AND resolved = false
      AND detected_at < now() - interval '6 hours'
  LOOP
    v_age := now() - v_a.detected_at;
    v_cycle := CASE WHEN v_age >= interval '48 hours' THEN 3
                    WHEN v_age >= interval '24 hours' THEN 2
                    ELSE 1 END;
    -- Dédup : une ré-alerte par (anomalie, cycle).
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE metadata->>'kind' = 'fatome_escalation'
        AND metadata->>'anomaly_id' = v_a.id::text
        AND metadata->>'cycle' = v_cycle::text
    ) THEN
      FOR p IN SELECT id FROM public.profiles WHERE role IN ('pdg','admin','ceo') LIMIT 5 LOOP
        BEGIN
          INSERT INTO public.notifications (user_id, title, message, type, metadata)
          VALUES (p.id,
            '🔴 Anomalie critique NON traitée (rappel ' || v_cycle || '/3)',
            v_a.anomaly_type || ' — détectée le ' || to_char(v_a.detected_at, 'DD/MM à HH24:MI')
              || ', toujours sans traitement. Réf ' || v_a.ref,
            'fatome_escalation',
            jsonb_build_object('kind', 'fatome_escalation', 'anomaly_id', v_a.id,
              'cycle', v_cycle, 'anomaly_type', v_a.anomaly_type, 'link', '/pdg?tab=fatome'));
        EXCEPTION WHEN OTHERS THEN NULL; END;
      END LOOP;
      v_raised := v_raised + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('escalations_raised', v_raised);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_escalation_sweep() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_escalation_sweep() TO service_role;

-- Niveau d'escalade pour le bandeau permanent (0 = rien ; 3 = bandeau rouge).
CREATE OR REPLACE FUNCTION public.fatome_escalation_level()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_over48 int; v_crit int;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT count(*) FILTER (WHERE detected_at < now() - interval '48 hours'), count(*)
  INTO v_over48, v_crit
  FROM public.fatome_anomalies WHERE severity = 'critical' AND resolved = false;
  RETURN jsonb_build_object('critical_unresolved', v_crit, 'over_48h', v_over48,
    'permanent_banner', v_over48 > 0);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_escalation_level() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_escalation_level() TO authenticated, service_role;

-- ── G) DIGEST QUOTIDIEN §6 — 07h00 Conakry (=UTC), SQL pur (survit au backend) ─
CREATE OR REPLACE FUNCTION public.fatome_daily_digest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_day date := (now() AT TIME ZONE 'UTC')::date - 1;  -- journée ÉCOULÉE
  v_moves bigint; v_anoms int; v_resolved int; v_hb record; v_age_min int;
  v_coffre text; v_msg text; p record; v_sent int := 0; v_t0 timestamptz := clock_timestamp();
BEGIN
  SELECT count(*) INTO v_moves FROM public.wallet_transactions
    WHERE created_at >= v_day AND created_at < v_day + 1;
  SELECT count(*), count(*) FILTER (WHERE resolved) INTO v_anoms, v_resolved
    FROM public.fatome_anomalies WHERE detected_at >= v_day AND detected_at < v_day + 1;
  SELECT * INTO v_hb FROM public.fatome_sentinel_heartbeat WHERE id = 1;
  v_age_min := COALESCE(round(extract(epoch from (now() - v_hb.last_beat))/60)::int, -1);
  SELECT COALESCE(string_agg(public._q_fmt_amount(w.balance, w.currency), ' · '), '—')
    INTO v_coffre
  FROM public.wallets w
  JOIN public.pdg_management m ON m.user_id = w.user_id AND m.is_active = true;

  v_msg := '🩺 Fatome — rapport du ' || to_char(v_day, 'DD/MM/YYYY') || ' : '
        || v_moves || ' mouvements wallet, ' || v_anoms || ' anomalie(s) (' || v_resolved || ' résolue(s)), '
        || CASE WHEN v_age_min BETWEEN 0 AND 15 THEN 'sentinelle OK (dernier passage il y a ' || v_age_min || ' min)'
                WHEN v_age_min > 15 THEN '⚠️ SENTINELLE MUETTE depuis ' || v_age_min || ' min'
                ELSE '⚠️ sentinelle sans battement' END
        || '. Coffre : ' || v_coffre || '.';

  -- Dédup : un digest par jour.
  FOR p IN SELECT id FROM public.profiles WHERE role IN ('pdg','admin','ceo') LIMIT 5 LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE user_id = p.id AND metadata->>'kind' = 'fatome_digest'
        AND metadata->>'day' = v_day::text
    ) THEN
      BEGIN
        INSERT INTO public.notifications (user_id, title, message, type, metadata)
        VALUES (p.id, '🩺 Fatome — rapport du matin', v_msg, 'fatome_digest',
          jsonb_build_object('kind', 'fatome_digest', 'day', v_day, 'link', '/pdg?tab=fatome'));
        v_sent := v_sent + 1;
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
  END LOOP;

  INSERT INTO public.fatome_activity_log (fatome_key, duration_ms, ok, message, volume)
  VALUES ('fatome_sentinelle', round(extract(milliseconds from (clock_timestamp() - v_t0)))::int,
          true, 'Digest quotidien envoyé', jsonb_build_object('digest_day', v_day, 'recipients', v_sent));

  RETURN jsonb_build_object('day', v_day, 'sent', v_sent, 'message', v_msg);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_daily_digest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_daily_digest() TO service_role;

-- ── H) §9.3 : le TICK pg_cron vérifie DÉSORMAIS aussi le GÉNÉRAL + escalade ──
-- Un seul point à vérifier de l'extérieur : le vérificateur bête contrôle la Sentinelle,
-- les triggers, ET le heartbeat du Général (qui vérifie le reste). + journal d'activité.
CREATE OR REPLACE FUNCTION public.fatome_deadman_tick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_gen record; v_day text := to_char((now() AT TIME ZONE 'UTC'), 'YYYY-MM-DD');
  v_t0 timestamptz := clock_timestamp(); v_sent jsonb; v_trig jsonb; v_esc jsonb;
BEGIN
  v_sent := public.fatome_sentinel_check();
  v_trig := public.fatome_triggers_health();
  v_esc  := public.fatome_escalation_sweep();

  -- Le Général : heartbeat attendu toutes les 5 min → mort au-delà de 15 min.
  SELECT * INTO v_gen FROM public.fatome_heartbeats WHERE fatome_key = 'fatome_general';
  IF v_gen.fatome_key IS NULL OR v_gen.last_beat < now() - interval '15 minutes' THEN
    PERFORM public.fatome_raise('sentinel:general_dead', 'monitor:sentinel:general_dead:'||v_day, 'critical',
      jsonb_build_object('last_beat', v_gen.last_beat,
        'age_min', CASE WHEN v_gen.last_beat IS NULL THEN NULL
                        ELSE round(extract(epoch from (now() - v_gen.last_beat))/60)::int END));
  ELSE
    PERFORM public.fatome_resolve_type('sentinel:general_dead');
  END IF;

  INSERT INTO public.fatome_activity_log (fatome_key, duration_ms, ok, message, volume)
  VALUES ('fatome_deadman', round(extract(milliseconds from (clock_timestamp() - v_t0)))::int, true,
          'Tick vérificateur externe', jsonb_build_object('sentinel', v_sent, 'triggers', v_trig, 'escalation', v_esc));
END; $fn$;
REVOKE ALL ON FUNCTION public.fatome_deadman_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_deadman_tick() TO service_role;

-- ── I) LECTURES PDG-ONLY pour la section (pagination SERVEUR partout) ────────
-- État des triggers SANS effet de bord (pour le bandeau de l'onglet Sentinelle).
CREATE OR REPLACE FUNCTION public.fatome_triggers_state()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_expected text[] := ARRAY['trg_fatome_agent_cash','trg_fatome_fx_transfer','trg_fatome_revenus_pdg','trg_fatome_wallet_tx'];
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN (SELECT jsonb_agg(jsonb_build_object('name', e,
    'exists', EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname = e AND NOT t.tgisinternal),
    'enabled', EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname = e AND NOT t.tgisinternal AND t.tgenabled <> 'D')))
    FROM unnest(v_expected) e);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_triggers_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_triggers_state() TO authenticated, service_role;

-- Alertes ACTIVES (non résolues), paginées.
CREATE OR REPLACE FUNCTION public.fatome_active_anomalies(p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_total bigint; v_rows jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT count(*) INTO v_total FROM public.fatome_anomalies WHERE resolved = false;
  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_rows FROM (
    SELECT id, anomaly_type, ref, severity, detail, detected_at
    FROM public.fatome_anomalies WHERE resolved = false
    ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END,
             detected_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,20),1),100) OFFSET GREATEST(COALESCE(p_offset,0),0)
  ) x;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_active_anomalies(int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_active_anomalies(int, int) TO authenticated, service_role;

-- HISTORIQUE complet, filtrable (période, sévérité, résolu, recherche), paginé serveur.
CREATE OR REPLACE FUNCTION public.fatome_anomalies_page(
  p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL,
  p_severity text DEFAULT NULL, p_resolved boolean DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_limit int DEFAULT 25, p_offset int DEFAULT 0
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_total bigint; v_rows jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT count(*) INTO v_total FROM public.fatome_anomalies a
  WHERE (p_from IS NULL OR a.detected_at >= p_from)
    AND (p_to IS NULL OR a.detected_at < p_to)
    AND (p_severity IS NULL OR a.severity = p_severity)
    AND (p_resolved IS NULL OR a.resolved = p_resolved)
    AND (p_search IS NULL OR a.anomaly_type ILIKE '%'||p_search||'%' OR a.ref ILIKE '%'||p_search||'%');
  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_rows FROM (
    SELECT id, anomaly_type, ref, severity, detail, resolved, detected_at,
           resolved_at, resolved_by, resolution_source
    FROM public.fatome_anomalies a
    WHERE (p_from IS NULL OR a.detected_at >= p_from)
      AND (p_to IS NULL OR a.detected_at < p_to)
      AND (p_severity IS NULL OR a.severity = p_severity)
      AND (p_resolved IS NULL OR a.resolved = p_resolved)
      AND (p_search IS NULL OR a.anomaly_type ILIKE '%'||p_search||'%' OR a.ref ILIKE '%'||p_search||'%')
    ORDER BY a.detected_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,25),1),200) OFFSET GREATEST(COALESCE(p_offset,0),0)
  ) x;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_anomalies_page(timestamptz, timestamptz, text, boolean, text, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_anomalies_page(timestamptz, timestamptz, text, boolean, text, int, int) TO authenticated, service_role;

-- JOURNAL D'ACTIVITÉ paginé (par Fatome ou tous).
CREATE OR REPLACE FUNCTION public.fatome_activity_page(
  p_key text DEFAULT NULL, p_limit int DEFAULT 30, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_total bigint; v_rows jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT count(*) INTO v_total FROM public.fatome_activity_log
    WHERE (p_key IS NULL OR fatome_key = p_key);
  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_rows FROM (
    SELECT id, fatome_key, run_at, duration_ms, ok, message, volume
    FROM public.fatome_activity_log
    WHERE (p_key IS NULL OR fatome_key = p_key)
    ORDER BY run_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit,30),1),200) OFFSET GREATEST(COALESCE(p_offset,0),0)
  ) x;
  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_activity_page(text, int, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_activity_page(text, int, int) TO authenticated, service_role;

-- ÉTAT GLOBAL de la section (bandeau des 2 onglets + pastilles accueil + bandeau escalade).
CREATE OR REPLACE FUNCTION public.fatome_section_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_hb record; v_reg jsonb; v_esc jsonb;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO v_hb FROM public.fatome_sentinel_heartbeat WHERE id = 1;
  SELECT jsonb_agg(jsonb_build_object(
      'fatome_key', r.fatome_key, 'label', r.label, 'criticality', r.criticality,
      'enabled', r.enabled, 'expected_interval_sec', r.expected_interval_sec,
      'last_beat', COALESCE(h.last_beat, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_beat END),
      'age_seconds', round(extract(epoch from (now() - COALESCE(h.last_beat,
          CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_beat END))))::int,
      'last_ok', COALESCE(h.last_ok, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_ok END),
      'last_error', COALESCE(h.last_error, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.last_error END),
      'cycle_count', COALESCE(h.cycle_count, CASE WHEN r.fatome_key='fatome_sentinelle' THEN v_hb.cycle_count END),
      'last_verdict', (SELECT jsonb_build_object('verdict', c.verdict, 'reason', c.reason, 'run_at', c.run_at)
                       FROM public.fatome_general_checks c
                       WHERE c.fatome_key = r.fatome_key ORDER BY c.run_at DESC LIMIT 1)
    ) ORDER BY r.fatome_key)
  INTO v_reg
  FROM public.fatome_registry r
  LEFT JOIN public.fatome_heartbeats h ON h.fatome_key = r.fatome_key;
  v_esc := public.fatome_escalation_level();
  RETURN jsonb_build_object(
    'sentinel', jsonb_build_object(
      'has_heartbeat', v_hb.id IS NOT NULL, 'last_beat', v_hb.last_beat,
      'age_seconds', round(extract(epoch from (now() - v_hb.last_beat)))::int,
      'last_ok', v_hb.last_ok, 'last_error', v_hb.last_error, 'cycle_count', v_hb.cycle_count),
    'registry', COALESCE(v_reg, '[]'::jsonb),
    'escalation', v_esc,
    'generated_at', now());
END; $$;
REVOKE ALL ON FUNCTION public.fatome_section_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_section_status() TO authenticated, service_role;

COMMIT;

-- ── J) PLANIFICATIONS pg_cron (hors transaction, défensives, sans doublon) ───
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    -- Digest quotidien 07h00 Conakry (= UTC).
    PERFORM cron.unschedule('fatome-daily-digest')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'fatome-daily-digest');
    PERFORM cron.schedule('fatome-daily-digest', '0 7 * * *', 'SELECT public.fatome_daily_digest();');
    -- Rétention du journal d'activité (90 j — le minimum exigé est 30 j).
    PERFORM cron.unschedule('fatome-activity-purge')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'fatome-activity-purge');
    PERFORM cron.schedule('fatome-activity-purge', '45 3 * * *',
      'DELETE FROM public.fatome_activity_log WHERE run_at < now() - interval ''90 days'';');
  ELSE
    RAISE NOTICE 'pg_cron absent : planifier fatome_daily_digest et la purge autrement.';
  END IF;
END $$;
