-- ============================================================================
-- Live Shopping — compteur de VUES d'un replay (page replay dédiée).
-- Colonne dénormalisée sur live_streams, incrémentée atomiquement côté backend
-- (service_role) — débounce « 1 vue / session » assuré côté client (sessionStorage).
-- Lecture publique héritée de live_streams_public_read.
-- ============================================================================

ALTER TABLE public.live_streams
  ADD COLUMN IF NOT EXISTS replay_views int NOT NULL DEFAULT 0;

-- Incrément atomique (jamais de lecture-puis-écriture côté client/backend).
CREATE OR REPLACE FUNCTION public.increment_replay_view(p_stream_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.live_streams
  SET replay_views = replay_views + 1
  WHERE id = p_stream_id AND status = 'ended';
END;
$$;

REVOKE ALL ON FUNCTION public.increment_replay_view(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.increment_replay_view(uuid) TO service_role;
