-- ════════════════════════════════════════════════════════════════════════════
-- CHANTIER 2 — Exposer recording_status dans l'espace Live vendeur (5 états du replay).
-- La RPC get_vendor_live_streams renvoyait un TABLE figé → on la recrée (DROP + CREATE) en
-- ajoutant recording_status. Corps identique par ailleurs.
-- ════════════════════════════════════════════════════════════════════════════

DROP FUNCTION IF EXISTS public.get_vendor_live_streams(uuid, int, int);

CREATE OR REPLACE FUNCTION public.get_vendor_live_streams(p_vendor_user_id uuid, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE(
  id uuid, title text, status text, thumbnail_url text, replay_url text, replay_expires_at timestamptz,
  total_likes int, replay_views int, viewer_count int, peak_viewer_count int,
  started_at timestamptz, ended_at timestamptz, created_at timestamptz,
  comments_count bigint, purchases_count bigint, recording_status text
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.title, s.status, s.thumbnail_url, s.replay_url, s.replay_expires_at,
    s.total_likes, s.replay_views, s.viewer_count, s.peak_viewer_count,
    s.started_at, s.ended_at, s.created_at,
    (SELECT count(*) FROM public.live_replay_comments c WHERE c.stream_id = s.id AND c.status = 'visible') AS comments_count,
    (SELECT count(*) FROM public.live_stream_events e WHERE e.live_stream_id = s.id AND e.event_type = 'purchase') AS purchases_count,
    s.recording_status
  FROM public.live_streams s
  WHERE s.vendor_user_id = p_vendor_user_id
  ORDER BY s.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 50)) OFFSET GREATEST(0, p_offset);
$$;

REVOKE ALL ON FUNCTION public.get_vendor_live_streams(uuid, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_vendor_live_streams(uuid, int, int) TO service_role;
