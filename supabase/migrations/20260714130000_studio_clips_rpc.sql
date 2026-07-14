-- ============================================================================
-- STUDIO CLIPS 224 — RPC de support pour A2 (endpoints) et A3 (worker ffmpeg).
-- Toutes SECURITY DEFINER, appelées par le backend/worker via service_role.
--   • create_clip_job     : validation (ownership, replay dispo, segments, quota) + insert 'queued' — atomique, idempotent.
--   • claim_next_clip_job : le worker prend le prochain job SERVEUR (concurrence 1, SKIP LOCKED).
--   • clip_watchdog       : passe en 'failed' les jobs 'processing' bloqués > 15 min (anti-zombie).
-- ============================================================================

-- Idempotence des créations de clip (Idempotency-key de l'endpoint POST /api/clips).
ALTER TABLE public.live_clips ADD COLUMN IF NOT EXISTS idempotency_key text;
CREATE UNIQUE INDEX IF NOT EXISTS ux_live_clips_idem
  ON public.live_clips (idempotency_key) WHERE idempotency_key IS NOT NULL;

-- ── A2 : création de job (validation complète + insert), atomique + idempotent ──
CREATE OR REPLACE FUNCTION public.create_clip_job(
  p_vendor_id      uuid,
  p_stream_id      uuid,
  p_title          text,
  p_segments       jsonb,     -- [{start_s, end_s}, ...] (1..3)
  p_overlay        jsonb,     -- {product_id, product_name, price, currency, show_logo}
  p_music_track_id uuid,
  p_cover_time_s   numeric,
  p_rendered_on    text,      -- 'device' | 'server'
  p_idempotency_key text
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg      public.clip_config;
  v_replay   text;
  v_n        int;
  v_total    numeric := 0;
  v_prev_end numeric := -1;
  v_s        numeric;
  v_e        numeric;
  v_seg      jsonb;
  v_count    int;
  v_id       uuid;
BEGIN
  -- Idempotence : même clé → renvoie le clip déjà créé.
  IF p_idempotency_key IS NOT NULL AND p_idempotency_key <> '' THEN
    SELECT id INTO v_id FROM public.live_clips WHERE idempotency_key = p_idempotency_key;
    IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  END IF;

  SELECT * INTO v_cfg FROM public.clip_config WHERE id;

  -- Ownership + replay disponible (le stream doit appartenir au vendeur et avoir un replay).
  SELECT replay_url INTO v_replay FROM public.live_streams
    WHERE id = p_stream_id AND vendor_id = p_vendor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'STREAM_INTROUVABLE'; END IF;
  IF v_replay IS NULL OR v_replay = '' THEN RAISE EXCEPTION 'REPLAY_INDISPONIBLE'; END IF;

  -- Rendu autorisé.
  IF COALESCE(p_rendered_on,'server') NOT IN ('device','server') THEN
    RAISE EXCEPTION 'RENDERED_ON_INVALIDE';
  END IF;

  -- Segments : 1..3, chacun 0 <= start < end, triés sans chevauchement, total <= max.
  v_n := COALESCE(jsonb_array_length(p_segments), 0);
  IF v_n < 1 OR v_n > 3 THEN RAISE EXCEPTION 'SEGMENTS_INVALIDES'; END IF;
  FOR v_seg IN SELECT e FROM jsonb_array_elements(p_segments) e ORDER BY (e->>'start_s')::numeric LOOP
    v_s := (v_seg->>'start_s')::numeric;
    v_e := (v_seg->>'end_s')::numeric;
    IF v_s IS NULL OR v_e IS NULL OR v_s < 0 OR v_e <= v_s THEN RAISE EXCEPTION 'SEGMENT_INVALIDE'; END IF;
    IF v_s < v_prev_end THEN RAISE EXCEPTION 'SEGMENTS_CHEVAUCHENT'; END IF;
    v_total := v_total + (v_e - v_s);
    v_prev_end := v_e;
  END LOOP;
  IF v_total <= 0 THEN RAISE EXCEPTION 'SEGMENTS_INVALIDES'; END IF;
  IF v_total > v_cfg.max_clip_duration_s THEN RAISE EXCEPTION 'DUREE_DEPASSEE'; END IF;

  -- Quota du jour (24h calendaires).
  SELECT count(*) INTO v_count FROM public.live_clips
    WHERE vendor_id = p_vendor_id AND created_at::date = now()::date;
  IF v_count >= v_cfg.max_clips_per_vendor_per_day THEN RAISE EXCEPTION 'QUOTA_ATTEINT'; END IF;

  INSERT INTO public.live_clips
    (vendor_id, stream_id, title, segments, overlay, music_track_id, cover_time_s, rendered_on, idempotency_key, status)
  VALUES
    (p_vendor_id, p_stream_id, COALESCE(NULLIF(p_title,''), 'Clip promo'),
     p_segments, COALESCE(p_overlay, '{}'::jsonb), p_music_track_id, p_cover_time_s,
     COALESCE(p_rendered_on, 'server'), NULLIF(p_idempotency_key, ''), 'queued')
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.create_clip_job(uuid,uuid,text,jsonb,jsonb,uuid,numeric,text,text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.create_clip_job(uuid,uuid,text,jsonb,jsonb,uuid,numeric,text,text) TO service_role;

-- ── A3 : le worker prend le prochain job SERVEUR (concurrence 1) ──
-- Les jobs 'device' rendent côté client et uploadent directement → le worker ne les touche pas.
CREATE OR REPLACE FUNCTION public.claim_next_clip_job()
RETURNS public.live_clips
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v public.live_clips;
BEGIN
  SELECT * INTO v FROM public.live_clips
   WHERE status = 'queued' AND rendered_on = 'server'
   ORDER BY created_at ASC
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;
  UPDATE public.live_clips SET status = 'processing', progress = 5 WHERE id = v.id;
  v.status := 'processing'; v.progress := 5;
  RETURN v;
END $$;
REVOKE ALL ON FUNCTION public.claim_next_clip_job() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.claim_next_clip_job() TO service_role;

-- ── A3 : watchdog anti-zombie (job 'processing' figé > 15 min → 'failed') ──
CREATE OR REPLACE FUNCTION public.clip_watchdog()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  WITH z AS (
    UPDATE public.live_clips
       SET status = 'failed', error = 'Timeout (watchdog > 15 min)'
     WHERE status = 'processing' AND updated_at < now() - interval '15 minutes'
    RETURNING 1
  ) SELECT count(*) INTO n FROM z;
  RETURN COALESCE(n, 0);
END $$;
REVOKE ALL ON FUNCTION public.clip_watchdog() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.clip_watchdog() TO service_role;
