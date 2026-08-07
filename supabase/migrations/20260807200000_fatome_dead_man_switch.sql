-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME SENTINELLE — DEAD MAN'S SWITCH (qui surveille le surveillant). VAGUE 1, cœur.
-- « 0 anomalie » et « le surveillant est mort » ne doivent PLUS s'afficher pareil.
-- 1) Heartbeat battu à chaque cycle de l'étage B. 2) Vérificateur INDÉPENDANT (pg_cron, SQL pur —
-- survit à la mort du backend) : pas de battement récent → anomalie sentinel_dead. 3) Santé des
-- triggers (étage A). 4) Registre des Fatomes (squelette du Général). AUCUN flux d'argent touché.
-- Blindage : RLS PDG-read, écriture service_role, idempotence (fatome_raise dédup réf datée), append-only.
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) HEARTBEAT (une seule ligne, id=1) ────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.fatome_sentinel_heartbeat (
  id int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  last_beat     timestamptz NOT NULL DEFAULT now(),
  last_ok       boolean     NOT NULL DEFAULT true,
  last_error    text,
  failing_since timestamptz,             -- posé quand last_ok bascule à false, effacé au retour ok
  cycle_count   bigint      NOT NULL DEFAULT 0,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.fatome_sentinel_heartbeat (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.fatome_sentinel_heartbeat ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fatome_hb_read_pdg ON public.fatome_sentinel_heartbeat;
CREATE POLICY fatome_hb_read_pdg ON public.fatome_sentinel_heartbeat FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());
-- Écriture : service_role via RPC uniquement (aucune policy INSERT/UPDATE).

-- Battement — appelé à CHAQUE cycle de l'étage B (service_role).
CREATE OR REPLACE FUNCTION public.fatome_heartbeat_beat(p_ok boolean, p_error text DEFAULT NULL, p_cycle bigint DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  UPDATE public.fatome_sentinel_heartbeat
  SET last_beat = now(),
      last_ok = COALESCE(p_ok, true),
      last_error = CASE WHEN COALESCE(p_ok,true) THEN NULL ELSE p_error END,
      failing_since = CASE WHEN COALESCE(p_ok,true) THEN NULL ELSE COALESCE(failing_since, now()) END,
      cycle_count = COALESCE(p_cycle, cycle_count + 1),
      updated_at = now()
  WHERE id = 1;
  IF NOT FOUND THEN
    INSERT INTO public.fatome_sentinel_heartbeat (id, last_ok, last_error, failing_since, cycle_count)
    VALUES (1, COALESCE(p_ok,true), CASE WHEN COALESCE(p_ok,true) THEN NULL ELSE p_error END,
            CASE WHEN COALESCE(p_ok,true) THEN NULL ELSE now() END, COALESCE(p_cycle,0))
    ON CONFLICT (id) DO NOTHING;
  END IF;
END; $fn$;
REVOKE ALL ON FUNCTION public.fatome_heartbeat_beat(boolean, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_heartbeat_beat(boolean, text, bigint) TO service_role;

-- ── 2) VÉRIFICATEUR INDÉPENDANT (SQL pur, planifié pg_cron) ──────────────────
-- last_beat > 15 min → sentinel_dead (critical). failing_since > 30 min → sentinel_failing (high).
-- Idempotent (fatome_raise dédup par réf DATÉE). Auto-résolution quand tout redevient sain.
CREATE OR REPLACE FUNCTION public.fatome_sentinel_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE hb record; v_age interval; v_day text := to_char((now() AT TIME ZONE 'UTC'), 'YYYY-MM-DD');
  v_dead boolean := false; v_failing boolean := false;
BEGIN
  SELECT * INTO hb FROM public.fatome_sentinel_heartbeat WHERE id = 1;
  IF hb.id IS NULL THEN
    PERFORM public.fatome_raise('sentinel:sentinel_dead', 'monitor:sentinel:sentinel_dead:'||v_day, 'critical',
      jsonb_build_object('reason','no_heartbeat_row'));
    RETURN jsonb_build_object('status','dead','reason','no_heartbeat');
  END IF;
  v_age := now() - hb.last_beat;

  IF v_age > interval '15 minutes' THEN
    v_dead := true;
    PERFORM public.fatome_raise('sentinel:sentinel_dead', 'monitor:sentinel:sentinel_dead:'||v_day, 'critical',
      jsonb_build_object('last_beat', hb.last_beat, 'age_min', round(extract(epoch from v_age)/60)::int, 'last_error', hb.last_error));
  ELSE
    PERFORM public.fatome_resolve_type('sentinel:sentinel_dead');
  END IF;

  IF NOT v_dead AND hb.failing_since IS NOT NULL AND hb.failing_since < now() - interval '30 minutes' THEN
    v_failing := true;
    PERFORM public.fatome_raise('sentinel:sentinel_failing', 'monitor:sentinel:sentinel_failing:'||v_day, 'high',
      jsonb_build_object('failing_since', hb.failing_since, 'last_error', hb.last_error));
  ELSIF NOT v_dead THEN
    PERFORM public.fatome_resolve_type('sentinel:sentinel_failing');
  END IF;

  RETURN jsonb_build_object('status', CASE WHEN v_dead THEN 'dead' WHEN v_failing THEN 'failing' ELSE 'ok' END,
    'age_min', round(extract(epoch from v_age)/60)::int, 'last_ok', hb.last_ok);
END; $fn$;
REVOKE ALL ON FUNCTION public.fatome_sentinel_check() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_sentinel_check() TO service_role;

-- ── 3) SANTÉ DES TRIGGERS (étage A) — existence + enabled ────────────────────
-- Un DROP accidentel ou un DISABLE par une future migration devient détectable (cécité invisible).
CREATE OR REPLACE FUNCTION public.fatome_triggers_health()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_expected text[] := ARRAY['trg_fatome_agent_cash','trg_fatome_fx_transfer','trg_fatome_revenus_pdg','trg_fatome_wallet_tx'];
  v_missing int; v_disabled int; v_day text := to_char((now() AT TIME ZONE 'UTC'),'YYYY-MM-DD');
BEGIN
  SELECT count(*) INTO v_missing FROM unnest(v_expected) e
    WHERE NOT EXISTS (SELECT 1 FROM pg_trigger t WHERE t.tgname = e AND NOT t.tgisinternal);
  SELECT count(*) INTO v_disabled FROM pg_trigger t
    WHERE t.tgname = ANY(v_expected) AND t.tgenabled = 'D';
  IF (v_missing + v_disabled) > 0 THEN
    PERFORM public.fatome_raise('sentinel:sentinel_trigger_blind', 'monitor:sentinel:sentinel_trigger_blind:'||v_day, 'critical',
      jsonb_build_object('missing', v_missing, 'disabled', v_disabled, 'expected', array_length(v_expected,1)));
  ELSE
    PERFORM public.fatome_resolve_type('sentinel:sentinel_trigger_blind');
  END IF;
  RETURN jsonb_build_object('expected', array_length(v_expected,1), 'missing', v_missing, 'disabled', v_disabled);
END; $fn$;
REVOKE ALL ON FUNCTION public.fatome_triggers_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_triggers_health() TO service_role;

-- Tick planifié = vérificateur + santé triggers (un seul job cron indépendant du backend).
CREATE OR REPLACE FUNCTION public.fatome_deadman_tick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  PERFORM public.fatome_sentinel_check();
  PERFORM public.fatome_triggers_health();
END; $fn$;
REVOKE ALL ON FUNCTION public.fatome_deadman_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_deadman_tick() TO service_role;

-- ── 4) REGISTRE DES FATOMES (squelette du Général — 9.1) ─────────────────────
CREATE TABLE IF NOT EXISTS public.fatome_registry (
  fatome_key text PRIMARY KEY,
  label text NOT NULL,
  heartbeat_source text,
  health_check_rpc text,
  expected_interval_sec int,
  criticality text NOT NULL DEFAULT 'high' CHECK (criticality IN ('low','medium','high','critical')),
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.fatome_registry (fatome_key, label, heartbeat_source, health_check_rpc, expected_interval_sec, criticality) VALUES
  ('fatome_sentinelle',     'Fatome Sentinelle',           'fatome_sentinel_heartbeat', 'fatome_sentinel_check', 90,   'critical'),
  ('fatome_x',              'Fatome X (taux de change)',    NULL,                        'fx_monitor_report',     3600, 'high'),
  ('fatome_fonctionnalites','Fatome Fonctionnalités',       NULL,                        NULL,                    120,  'high')
ON CONFLICT (fatome_key) DO NOTHING;
ALTER TABLE public.fatome_registry ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS fatome_registry_read_pdg ON public.fatome_registry;
CREATE POLICY fatome_registry_read_pdg ON public.fatome_registry FOR SELECT TO authenticated
  USING (public.is_admin_or_pdg());

-- ── 5) STATUT pour la carte PDG (PDG-only) ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.fatome_sentinel_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE hb record;
BEGIN
  IF NOT public.is_admin_or_pdg() THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO hb FROM public.fatome_sentinel_heartbeat WHERE id = 1;
  IF hb.id IS NULL THEN RETURN jsonb_build_object('has_heartbeat', false); END IF;
  RETURN jsonb_build_object(
    'has_heartbeat', true,
    'last_beat', hb.last_beat,
    'age_seconds', round(extract(epoch from (now() - hb.last_beat)))::int,
    'last_ok', hb.last_ok,
    'last_error', hb.last_error,
    'cycle_count', hb.cycle_count,
    'fresh', (now() - hb.last_beat) < interval '5 minutes');
END; $fn$;
REVOKE ALL ON FUNCTION public.fatome_sentinel_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fatome_sentinel_status() TO authenticated, service_role;

COMMIT;

-- ── 6) PLANIFICATION pg_cron (hors transaction) — vérificateur toutes les 10 min ──
-- Indépendant du backend : si le backend meurt, le heartbeat vieillit et CE job lève sentinel_dead.
SELECT cron.schedule('fatome-deadman', '*/10 * * * *', 'SELECT public.fatome_deadman_tick();');
