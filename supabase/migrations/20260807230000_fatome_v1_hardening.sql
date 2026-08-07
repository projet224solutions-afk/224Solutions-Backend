-- ═══════════════════════════════════════════════════════════════════════════
-- FATOME VAGUE 1 — CORRECTIFS (4 points, mission dédiée).
-- 1) Digest du matin au FORMAT exigé : « N conversions FX, X anomalies (Y résolues),
--    sentinelle OK (dernier battement il y a Z min), Fatomes : X ✓ Sentinelle ✓ Général ✓ »
--    (+ coffre par devise, conservé du §6 d'origine). Idempotent (1/jour), non bloquant.
--    NB : le digest EXISTAIT (20260807220000, cron 07h00 actif, prouvé) — ceci le met au format.
-- 2) Sécurité œil externe : VUE dédiée fatome_heartbeat_public (last_beat/last_ok, id=1)
--    lisible en anon → le workflow GitHub n'a PLUS besoin de la clé service_role.
-- 3) Robustesse : replanification du vérificateur GARDÉE par la présence de pg_cron
--    (la ligne non gardée de 20260807200000 reste historique — jamais éditée).
-- Migration NOUVELLE.
-- ═══════════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1) DIGEST v2 — format exigé ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fatome_daily_digest()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_day date := (now() AT TIME ZONE 'UTC')::date - 1;  -- journée ÉCOULÉE (Conakry = UTC)
  v_fx bigint; v_anoms int; v_resolved int; v_hb record; v_age_min int;
  v_x_ok boolean; v_gen_ok boolean; v_coffre text; v_msg text; p record;
  v_sent int := 0; v_t0 timestamptz := clock_timestamp();
BEGIN
  -- Conversions FX du jour = lignes enhanced_transactions marquées fx=true
  -- (même définition que le trigger étage A trg_fatome_fx_transfer).
  SELECT count(*) INTO v_fx FROM public.enhanced_transactions
    WHERE created_at >= v_day AND created_at < v_day + 1
      AND COALESCE(metadata->>'fx', 'false') = 'true';
  SELECT count(*), count(*) FILTER (WHERE resolved) INTO v_anoms, v_resolved
    FROM public.fatome_anomalies WHERE detected_at >= v_day AND detected_at < v_day + 1;
  SELECT * INTO v_hb FROM public.fatome_sentinel_heartbeat WHERE id = 1;
  v_age_min := COALESCE(round(extract(epoch from (now() - v_hb.last_beat))/60)::int, -1);

  -- Checklist des Fatomes : dernier verdict du Général (X) + heartbeats frais.
  SELECT (verdict = 'SAIN') INTO v_x_ok FROM public.fatome_general_checks
    WHERE fatome_key = 'fatome_x' ORDER BY run_at DESC LIMIT 1;
  SELECT (last_beat > now() - interval '15 minutes') INTO v_gen_ok
    FROM public.fatome_heartbeats WHERE fatome_key = 'fatome_general';

  SELECT COALESCE(string_agg(public._q_fmt_amount(w.balance, w.currency), ' · '), '—')
    INTO v_coffre
  FROM public.wallets w
  JOIN public.pdg_management m ON m.user_id = w.user_id AND m.is_active = true;

  v_msg := '🩺 Fatome — rapport du ' || to_char(v_day, 'DD/MM/YYYY') || ' : '
        || v_fx || ' conversion(s) FX, '
        || v_anoms || ' anomalie(s) (' || v_resolved || ' résolue(s)), '
        || CASE WHEN v_age_min BETWEEN 0 AND 15 THEN 'sentinelle OK (dernier battement il y a ' || v_age_min || ' min)'
                WHEN v_age_min > 15 THEN '⚠️ SENTINELLE MUETTE depuis ' || v_age_min || ' min'
                ELSE '⚠️ sentinelle sans battement' END
        || '. Fatomes : X ' || CASE WHEN COALESCE(v_x_ok, false) THEN '✓' ELSE '⚠️' END
        || ' Sentinelle ' || CASE WHEN v_age_min BETWEEN 0 AND 15 THEN '✓' ELSE '⚠️' END
        || ' Général ' || CASE WHEN COALESCE(v_gen_ok, false) THEN '✓' ELSE '⚠️' END
        || '. Coffre : ' || v_coffre || '.';

  -- Idempotent : UN digest max par jour et par destinataire (clé datée en metadata).
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
          true, 'Digest quotidien', jsonb_build_object('digest_day', v_day, 'recipients', v_sent, 'fx', v_fx));

  RETURN jsonb_build_object('day', v_day, 'sent', v_sent, 'message', v_msg);
END; $$;
REVOKE ALL ON FUNCTION public.fatome_daily_digest() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fatome_daily_digest() TO service_role;

-- ── 2) VUE PUBLIQUE MINIMALE pour l'œil externe ─────────────────────────────
-- COMPROMIS ASSUMÉ (documenté) : exposer en anon UNIQUEMENT last_beat/last_ok de la
-- ligne id=1 — un timestamp et un booléen, aucune donnée métier, aucune structure
-- interne. Ça permet au workflow GitHub de vérifier le heartbeat SANS la clé
-- service_role (qui donnait l'accès TOTAL à la base depuis un secret GitHub).
CREATE OR REPLACE VIEW public.fatome_heartbeat_public AS
  SELECT last_beat, last_ok FROM public.fatome_sentinel_heartbeat WHERE id = 1;
REVOKE ALL ON public.fatome_heartbeat_public FROM PUBLIC;
GRANT SELECT ON public.fatome_heartbeat_public TO anon, authenticated, service_role;

COMMIT;

-- ── 3) REPLANIFICATION GARDÉE du vérificateur (hors transaction) ────────────
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('fatome-deadman')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'fatome-deadman');
    PERFORM cron.schedule('fatome-deadman', '*/10 * * * *', 'SELECT public.fatome_deadman_tick();');
  ELSE
    RAISE WARNING 'pg_cron absent : vérificateur non planifié — activer l''extension puis re-exécuter ; le repli GitHub Actions (déjà en place) fait office d''œil externe.';
  END IF;
END $$;
