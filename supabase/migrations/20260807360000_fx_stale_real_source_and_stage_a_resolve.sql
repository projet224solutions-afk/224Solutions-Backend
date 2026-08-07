-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME X — le gardien FX regardait la MAUVAISE SOURCE + les anomalies de l'étage A
-- n'avaient aucun resolver.
--
-- CONSTAT ÉCRAN PDG (07/08 soir) : onglet « Fatome X » en DEGRADE, `fx_pair_stale` = 12,
-- alors que la carte Exchange affiche 294 paires fraîches et 0 périmée.
-- CAUSE : `fx_monitor_report.fx_pair_stale` compte les paires de `fx_pair_bounds` sans taux
-- frais dans **`fx_rates_ledger`** — or ce ledger n'est PAS alimenté par le collecteur en
-- service (il écrit dans `currency_exchange_rates`, la source canonique ; l'en-tête de
-- 20260712120000 le dit : « les scrapers alimenteront fx_ingest_rate »). Le gardien
-- surveillait donc un livre vide : faux positif structurel, critique et permanent.
--
-- CORRECTIF 1 : une paire est FRAÎCHE si elle a un taux frais dans le ledger **OU** dans
-- `currency_exchange_rates`. Le jour où le ledger sera alimenté, rien à changer.
--
-- CORRECTIF 2 : les anomalies de l'ÉTAGE A (triggers sur les tables d'argent) sont
-- PONCTUELLES (une par opération suspecte) et n'ont, par nature, aucun resolver : elles
-- restent « non résolues » à vie et polluent le compteur du PDG. On ajoute une
-- auto-résolution des anomalies de l'étage A **sans récurrence depuis 7 jours** (le fait
-- reste dans l'historique, il sort seulement des alertes actives) — même discipline que
-- l'auto-résolution des alertes événementielles existante.
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) fx_pair_stale : la VRAIE source (ledger OU currency_exchange_rates) ──
CREATE OR REPLACE FUNCTION public.fx_monitor_report()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_quarantine int; v_verification int; v_stale int; v_rejected_24h int;
BEGIN
  SELECT count(*) INTO v_quarantine FROM public.fx_rates_ledger
    WHERE status='quarantine' AND created_at < now() - interval '2 hours';
  SELECT count(*) INTO v_verification FROM public.fx_rates_ledger WHERE status='verification';
  SELECT count(*) INTO v_rejected_24h FROM public.fx_rates_ledger
    WHERE status='rejected' AND created_at > now() - interval '24 hours';

  -- Paire fraîche = taux < 24 h dans le LEDGER **ou** dans currency_exchange_rates
  -- (source réellement alimentée par le collecteur horaire). `fx_pair_bounds.pair` est
  -- de la forme 'EUR/GNF' ou 'EUR-GNF' → on compare aux deux colonnes.
  SELECT count(*) INTO v_stale
  FROM public.fx_pair_bounds b
  WHERE NOT EXISTS (
          SELECT 1 FROM public.fx_rates_ledger l
          WHERE l.pair = b.pair AND l.status = 'active'
            AND l.collected_at > now() - interval '24 hours')
    AND NOT EXISTS (
          SELECT 1 FROM public.currency_exchange_rates r
          WHERE upper(r.from_currency) = upper(split_part(replace(b.pair, '-', '/'), '/', 1))
            AND upper(r.to_currency)   = upper(split_part(replace(b.pair, '-', '/'), '/', 2))
            AND r.retrieved_at > now() - interval '24 hours');

  RETURN jsonb_build_object('generated_at', now(), 'checks', jsonb_build_array(
    jsonb_build_object('key','fx_quarantine_stuck','label','Taux en quarantaine > 2h non traités','severity','critical','count',v_quarantine,'observed',v_quarantine),
    jsonb_build_object('key','fx_verification_open','label','Taux en vérification (divergence)','severity','warning','count',v_verification,'observed',v_verification),
    jsonb_build_object('key','fx_pair_stale','label','Paires sans taux frais < 24h (ledger ou table canonique)','severity','critical','count',v_stale,'observed',v_stale),
    jsonb_build_object('key','fx_rejected_24h','label','Taux rejetés (hors bornes) 24h','severity','warning','count',v_rejected_24h,'observed',v_rejected_24h)
  ));
END $$;
REVOKE ALL ON FUNCTION public.fx_monitor_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fx_monitor_report() TO authenticated, service_role;

-- ── 2) Auto-résolution des anomalies de l'ÉTAGE A sans récurrence ───────────
-- Les triggers d'argent lèvent une anomalie PAR OPÉRATION (réf = id de la ligne) : il ne
-- peut pas exister de « retour à la normale » pour un fait passé. Sans balayage, elles
-- restent actives à vie. On les résout après 7 jours SANS nouvelle occurrence du même type.
CREATE OR REPLACE FUNCTION public.fatome_autoresolve_stage_a(p_days int DEFAULT 7)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_types text[] := ARRAY[
    'wallet_tx_no_ledger','agent_cash_imbalance','revenus_pdg_orphan',
    'fx_transfer_no_rate','fx_transfer_conservation'];
  v_t text; v_last timestamptz; v_n int := 0; v_total int := 0; v_resolved jsonb := '[]'::jsonb;
BEGIN
  FOREACH v_t IN ARRAY v_types LOOP
    SELECT max(detected_at) INTO v_last FROM public.fatome_anomalies WHERE anomaly_type = v_t;
    IF v_last IS NULL OR v_last > now() - make_interval(days => GREATEST(COALESCE(p_days,7),1)) THEN
      CONTINUE;   -- récurrence récente → on garde l'alerte ACTIVE
    END IF;
    UPDATE public.fatome_anomalies
    SET resolved = true, resolved_at = COALESCE(resolved_at, now()),
        resolution_source = COALESCE(resolution_source, 'auto_stage_a_no_recurrence')
    WHERE anomaly_type = v_t AND resolved = false;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n > 0 THEN
      v_total := v_total + v_n;
      v_resolved := v_resolved || jsonb_build_object('type', v_t, 'resolved', v_n, 'last_seen', v_last);
    END IF;
  END LOOP;
  RETURN jsonb_build_object('resolved_total', v_total, 'detail', v_resolved);
END $$;
REVOKE ALL ON FUNCTION public.fatome_autoresolve_stage_a(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_autoresolve_stage_a(int) TO service_role;

-- ── 3) Cadence attendue de fatome_x alignée sur le collecteur (horaire) ─────
-- Le collecteur tourne toutes les heures (cron african-fx-hourly '0 * * * *') → 3600 s.
-- La tolérance du Général est de 3× l'intervalle : un cycle manqué ne déclenche donc rien.
UPDATE public.fatome_registry
SET expected_interval_sec = 3600, heartbeat_source = 'fatome_heartbeats'
WHERE fatome_key = 'fatome_x';

COMMIT;

-- Le balayage de l'étage A tourne avec le tick du vérificateur (déjà planifié) : on
-- l'ajoute au tick pour ne pas multiplier les jobs.
CREATE OR REPLACE FUNCTION public.fatome_deadman_tick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_gen record; v_day text := to_char((now() AT TIME ZONE 'UTC'), 'YYYY-MM-DD');
  v_t0 timestamptz := clock_timestamp(); v_sent jsonb; v_trig jsonb; v_esc jsonb; v_sa jsonb;
BEGIN
  v_sent := public.fatome_sentinel_check();
  v_trig := public.fatome_triggers_health();
  v_esc  := public.fatome_escalation_sweep();
  v_sa   := public.fatome_autoresolve_stage_a(7);

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
          'Tick vérificateur externe',
          jsonb_build_object('sentinel', v_sent, 'triggers', v_trig, 'escalation', v_esc, 'stage_a', v_sa));
END; $fn$;
REVOKE ALL ON FUNCTION public.fatome_deadman_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_deadman_tick() TO service_role;
