-- ============================================================================
-- 🎥 LIVE SHOPPING — Vague 1 (schéma NEUTRE vis-à-vis du transport vidéo)
-- ----------------------------------------------------------------------------
-- Vendeurs qui vendent en direct vidéo (style Taobao/TikTok Live). Le transport
-- (Agora en Vague 1, LiveKit en Vague 2) est stocké de façon générique : colonne
-- `transport` + `channel` neutre (jamais de agora_*). Voir
-- docs/LIVE_TRANSPORT_ARCHITECTURE.md (frontend).
--
-- Tables : live_streams, live_stream_products, live_stream_events.
-- RLS : lecture publique des lives visibles (live OU replay non expiré), écriture
-- réservée au host. RPC SECURITY DEFINER (REVOKE anon/authenticated + GRANT
-- service_role, host vérifié DANS la fonction).
-- Migration livrée — NON exécutée.
-- ============================================================================

-- ── Tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.live_streams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  vendor_user_id uuid NOT NULL,
  title text NOT NULL,
  status text NOT NULL DEFAULT 'scheduled' CHECK (status IN ('scheduled','live','ended')),
  vendor_kind text NOT NULL DEFAULT 'physical' CHECK (vendor_kind IN ('physical','digital')),
  country_code text,
  transport text NOT NULL DEFAULT 'agora',
  channel text NOT NULL UNIQUE,
  thumbnail_url text,
  replay_url text,
  replay_expires_at timestamptz,
  viewer_count int NOT NULL DEFAULT 0,
  peak_viewer_count int NOT NULL DEFAULT 0,
  started_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.live_stream_products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  live_stream_id uuid NOT NULL REFERENCES public.live_streams(id) ON DELETE CASCADE,
  product_id uuid NOT NULL,
  is_pinned boolean NOT NULL DEFAULT false,
  display_order int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (live_stream_id, product_id)
);

CREATE TABLE IF NOT EXISTS public.live_stream_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  live_stream_id uuid NOT NULL REFERENCES public.live_streams(id) ON DELETE CASCADE,
  user_id uuid,
  event_type text NOT NULL CHECK (event_type IN ('join','leave','purchase','reaction')),
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ── Index ────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_live_streams_status  ON public.live_streams(status) WHERE status = 'live';
CREATE INDEX IF NOT EXISTS idx_live_streams_country ON public.live_streams(country_code, status);
CREATE INDEX IF NOT EXISTS idx_live_streams_replay  ON public.live_streams(replay_expires_at) WHERE status = 'ended';
CREATE INDEX IF NOT EXISTS idx_live_products_stream ON public.live_stream_products(live_stream_id);
CREATE INDEX IF NOT EXISTS idx_live_events_stream   ON public.live_stream_events(live_stream_id);

-- ── RLS ──────────────────────────────────────────────────────────────────────
ALTER TABLE public.live_streams          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_stream_products  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.live_stream_events    ENABLE ROW LEVEL SECURITY;

-- live_streams : lecture publique si live OU replay non expiré ; le host voit toujours les siens.
DROP POLICY IF EXISTS live_streams_public_read ON public.live_streams;
CREATE POLICY live_streams_public_read ON public.live_streams
  FOR SELECT
  USING (
    status = 'live'
    OR (status = 'ended' AND replay_expires_at IS NOT NULL AND replay_expires_at > now())
    OR vendor_user_id = auth.uid()
  );

DROP POLICY IF EXISTS live_streams_host_insert ON public.live_streams;
CREATE POLICY live_streams_host_insert ON public.live_streams
  FOR INSERT TO authenticated
  WITH CHECK (vendor_user_id = auth.uid());

DROP POLICY IF EXISTS live_streams_host_update ON public.live_streams;
CREATE POLICY live_streams_host_update ON public.live_streams
  FOR UPDATE TO authenticated
  USING (vendor_user_id = auth.uid())
  WITH CHECK (vendor_user_id = auth.uid());

-- live_stream_products : lecture publique si le live parent est visible ; écriture host.
DROP POLICY IF EXISTS live_products_public_read ON public.live_stream_products;
CREATE POLICY live_products_public_read ON public.live_stream_products
  FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM public.live_streams s
    WHERE s.id = live_stream_id
      AND (s.status = 'live'
        OR (s.status = 'ended' AND s.replay_expires_at IS NOT NULL AND s.replay_expires_at > now())
        OR s.vendor_user_id = auth.uid())
  ));

DROP POLICY IF EXISTS live_products_host_write ON public.live_stream_products;
CREATE POLICY live_products_host_write ON public.live_stream_products
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.live_streams s WHERE s.id = live_stream_id AND s.vendor_user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.live_streams s WHERE s.id = live_stream_id AND s.vendor_user_id = auth.uid()));

-- live_stream_events : INSERT authentifié (join/leave/purchase/reaction) ; SELECT host + admin.
DROP POLICY IF EXISTS live_events_auth_insert ON public.live_stream_events;
CREATE POLICY live_events_auth_insert ON public.live_stream_events
  FOR INSERT TO authenticated
  WITH CHECK (true);

DROP POLICY IF EXISTS live_events_host_read ON public.live_stream_events;
CREATE POLICY live_events_host_read ON public.live_stream_events
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg(auth.uid())
    OR EXISTS (SELECT 1 FROM public.live_streams s WHERE s.id = live_stream_id AND s.vendor_user_id = auth.uid())
  );

-- ── RPC (SECURITY DEFINER, host vérifié DANS la fonction) ────────────────────

-- Démarre un live : passe 'scheduled' → 'live', pose started_at. Host uniquement.
CREATE OR REPLACE FUNCTION public.start_live_stream(p_stream_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_owner uuid; v_status text; v_channel text;
BEGIN
  SELECT vendor_user_id, status, channel INTO v_owner, v_status, v_channel
  FROM public.live_streams WHERE id = p_stream_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Live introuvable'; END IF;
  IF v_owner <> auth.uid() THEN RAISE EXCEPTION 'Non autorisé : réservé au vendeur hôte'; END IF;
  IF v_status = 'ended' THEN RAISE EXCEPTION 'Live déjà terminé'; END IF;

  UPDATE public.live_streams
  SET status = 'live', started_at = COALESCE(started_at, now())
  WHERE id = p_stream_id;

  RETURN jsonb_build_object('success', true, 'stream_id', p_stream_id, 'channel', v_channel, 'status', 'live');
END;
$$;

-- Termine un live : 'ended', enregistre le replay (expire à +30 jours). Host uniquement.
CREATE OR REPLACE FUNCTION public.end_live_stream(p_stream_id uuid, p_replay_url text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_owner uuid; v_status text;
BEGIN
  SELECT vendor_user_id, status INTO v_owner, v_status
  FROM public.live_streams WHERE id = p_stream_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Live introuvable'; END IF;
  IF v_owner <> auth.uid() THEN RAISE EXCEPTION 'Non autorisé : réservé au vendeur hôte'; END IF;
  IF v_status = 'ended' THEN
    RETURN jsonb_build_object('success', true, 'already_ended', true, 'stream_id', p_stream_id);
  END IF;

  UPDATE public.live_streams
  SET status = 'ended',
      ended_at = now(),
      replay_url = p_replay_url,
      replay_expires_at = CASE WHEN p_replay_url IS NOT NULL THEN now() + interval '30 days' ELSE NULL END,
      viewer_count = 0
  WHERE id = p_stream_id;

  RETURN jsonb_build_object('success', true, 'stream_id', p_stream_id,
    'replay_url', p_replay_url,
    'replay_expires_at', (SELECT replay_expires_at FROM public.live_streams WHERE id = p_stream_id));
END;
$$;

-- Ajuste le nombre de spectateurs (+1 join / -1 leave) et met à jour le pic. Jamais négatif.
CREATE OR REPLACE FUNCTION public.adjust_live_viewers(p_stream_id uuid, p_delta int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_new int;
BEGIN
  UPDATE public.live_streams
  SET viewer_count = GREATEST(0, viewer_count + COALESCE(p_delta, 0)),
      peak_viewer_count = GREATEST(peak_viewer_count, GREATEST(0, viewer_count + COALESCE(p_delta, 0)))
  WHERE id = p_stream_id AND status = 'live'
  RETURNING viewer_count INTO v_new;
  IF v_new IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'stream_not_live');
  END IF;
  RETURN jsonb_build_object('success', true, 'viewer_count', v_new);
END;
$$;

-- Renvoie les replays expirés (id + url) pour purge GCS. Réservé service_role (job/edge).
CREATE OR REPLACE FUNCTION public.purge_expired_replays()
RETURNS TABLE(id uuid, replay_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT s.id, s.replay_url
  FROM public.live_streams s
  WHERE s.status = 'ended'
    AND s.replay_expires_at IS NOT NULL
    AND s.replay_expires_at <= now()
    AND s.replay_url IS NOT NULL;
END;
$$;

-- ── Grants : SECURITY DEFINER sensibles = service_role uniquement ────────────
-- (le backend, en service_role, vérifie le host applicativement ET la fonction re-vérifie
--  auth.uid() ; exposition PostgREST retirée pour anon/authenticated.)
REVOKE ALL ON FUNCTION public.start_live_stream(uuid)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.end_live_stream(uuid, text)       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.adjust_live_viewers(uuid, int)    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.purge_expired_replays()           FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_live_stream(uuid)         TO service_role;
GRANT EXECUTE ON FUNCTION public.end_live_stream(uuid, text)     TO service_role;
GRANT EXECUTE ON FUNCTION public.adjust_live_viewers(uuid, int)  TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_expired_replays()         TO service_role;

SELECT '✅ live_shopping : 3 tables + 5 index + RLS + 4 RPC (service_role) livrés' AS status;
