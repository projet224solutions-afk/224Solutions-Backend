-- ============================================================================
-- Espace « Live » du vendeur : agrégats de SES lives/replays en UNE requête (pas N).
-- Deux RPC SECURITY DEFINER (appelées par le backend en service_role, acteur passé
-- explicitement) : la liste paginée avec compteurs par live, et les totaux globaux.
-- Données déjà en base : total_likes, replay_views, live_replay_comments,
-- live_stream_events (event_type 'purchase'), viewer_count/peak.
-- ============================================================================

-- Liste des lives d'un vendeur avec compteurs par ligne (sous-requêtes corrélées =
-- un seul aller-retour DB, jamais N appels par ligne côté application).
CREATE OR REPLACE FUNCTION public.get_vendor_live_streams(p_vendor_user_id uuid, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE(
  id uuid, title text, status text, thumbnail_url text, replay_url text, replay_expires_at timestamptz,
  total_likes int, replay_views int, viewer_count int, peak_viewer_count int,
  started_at timestamptz, ended_at timestamptz, created_at timestamptz,
  comments_count bigint, purchases_count bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.id, s.title, s.status, s.thumbnail_url, s.replay_url, s.replay_expires_at,
    s.total_likes, s.replay_views, s.viewer_count, s.peak_viewer_count,
    s.started_at, s.ended_at, s.created_at,
    (SELECT count(*) FROM public.live_replay_comments c WHERE c.stream_id = s.id AND c.status = 'visible') AS comments_count,
    (SELECT count(*) FROM public.live_stream_events e WHERE e.live_stream_id = s.id AND e.event_type = 'purchase') AS purchases_count
  FROM public.live_streams s
  WHERE s.vendor_user_id = p_vendor_user_id
  ORDER BY s.created_at DESC
  LIMIT GREATEST(1, LEAST(p_limit, 50)) OFFSET GREATEST(0, p_offset);
$$;

-- Totaux globaux (tous les lives du vendeur).
CREATE OR REPLACE FUNCTION public.get_vendor_live_totals(p_vendor_user_id uuid)
RETURNS TABLE(
  streams_count bigint, total_likes bigint, total_replay_views bigint,
  total_comments bigint, total_purchases bigint
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    (SELECT count(*) FROM public.live_streams s WHERE s.vendor_user_id = p_vendor_user_id),
    (SELECT COALESCE(sum(s.total_likes), 0) FROM public.live_streams s WHERE s.vendor_user_id = p_vendor_user_id),
    (SELECT COALESCE(sum(s.replay_views), 0) FROM public.live_streams s WHERE s.vendor_user_id = p_vendor_user_id),
    (SELECT count(*) FROM public.live_replay_comments c
       JOIN public.live_streams s ON s.id = c.stream_id
      WHERE s.vendor_user_id = p_vendor_user_id AND c.status = 'visible'),
    (SELECT count(*) FROM public.live_stream_events e
       JOIN public.live_streams s ON s.id = e.live_stream_id
      WHERE s.vendor_user_id = p_vendor_user_id AND e.event_type = 'purchase');
$$;

REVOKE ALL ON FUNCTION public.get_vendor_live_streams(uuid, int, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_vendor_live_totals(uuid)            FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_vendor_live_streams(uuid, int, int) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_vendor_live_totals(uuid)            TO service_role;
