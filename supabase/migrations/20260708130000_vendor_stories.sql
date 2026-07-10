-- ============================================================================
-- Stories vendeur 24h — média éphémère (image/vidéo courte) visible 24h.
-- Anneau sur l'avatar boutique tant qu'une story est active ; visionneuse plein
-- écran tap-to-next côté client.
--
-- SÉCURITÉ (corrections revue adversariale) :
-- - Écritures 100% BACKEND (service_role) : AUCUNE policy INSERT/UPDATE/DELETE pour
--   authenticated. Sinon le garde media_url (anti-SSRF/anti-tracking) côté backend
--   serait contournable par un INSERT PostgREST direct.
-- - Compteur de vues via RPC increment_story_view(story_id, viewer_id) : viewer_id
--   passé EXPLICITEMENT par la route (auth.uid() = NULL sous service_role), sinon
--   UNIQUE(story_id, viewer_id) ne dédoublonne pas (NULL distincts) → view_count faux.
-- - expires_at fixé au DEFAULT DB (+24h), jamais envoyé par le client.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.vendor_stories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id uuid NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  vendor_user_id uuid NOT NULL,
  media_url text NOT NULL,
  media_type text NOT NULL CHECK (media_type IN ('image','video')),
  thumbnail_url text,
  caption text,
  duration_ms int,
  country_code text,
  view_count int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours')
);

-- Dédup des vues (état "vu" + comptage) : une ligne par (story, viewer).
CREATE TABLE IF NOT EXISTS public.story_views (
  story_id uuid NOT NULL REFERENCES public.vendor_stories(id) ON DELETE CASCADE,
  viewer_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (story_id, viewer_id)
);

CREATE INDEX IF NOT EXISTS idx_vendor_stories_expiry ON public.vendor_stories(expires_at);
CREATE INDEX IF NOT EXISTS idx_vendor_stories_vendor ON public.vendor_stories(vendor_user_id, created_at DESC);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.vendor_stories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.story_views    ENABLE ROW LEVEL SECURITY;

-- Lecture publique des stories NON expirées (ou les siennes). Aucune écriture client
-- (service_role bypass la RLS) → le garde media_url backend est la seule porte d'entrée.
DROP POLICY IF EXISTS vendor_stories_public_read ON public.vendor_stories;
CREATE POLICY vendor_stories_public_read ON public.vendor_stories
  FOR SELECT
  USING (expires_at > now() OR vendor_user_id = auth.uid());

-- Vues : lecture réservée au propriétaire de la story + admin (analytics privée).
-- Écriture uniquement via la RPC (service_role) — pas de policy INSERT.
DROP POLICY IF EXISTS story_views_owner_read ON public.story_views;
CREATE POLICY story_views_owner_read ON public.story_views
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_pdg(auth.uid())
    OR EXISTS (SELECT 1 FROM public.vendor_stories s WHERE s.id = story_id AND s.vendor_user_id = auth.uid())
  );

-- ── RPC ─────────────────────────────────────────────────────────────────────

-- Incrément atomique "première vue seulement" : le view_count n'augmente QUE si
-- l'INSERT a créé une ligne (ON CONFLICT DO NOTHING). Jamais de lecture-puis-écriture.
CREATE OR REPLACE FUNCTION public.increment_story_view(p_story_id uuid, p_viewer_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  WITH ins AS (
    INSERT INTO public.story_views(story_id, viewer_id)
    VALUES (p_story_id, p_viewer_id)
    ON CONFLICT (story_id, viewer_id) DO NOTHING
    RETURNING 1
  )
  UPDATE public.vendor_stories
  SET view_count = view_count + 1
  WHERE id = p_story_id AND EXISTS (SELECT 1 FROM ins);
END;
$$;

-- Purge des stories expirées : rend les médias pour purge du stockage (calqué sur
-- purge_expired_replays). Branchée sur le même job de purge que les replays.
CREATE OR REPLACE FUNCTION public.purge_expired_stories()
RETURNS TABLE(id uuid, media_url text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  DELETE FROM public.vendor_stories s
  WHERE s.expires_at <= now()
  RETURNING s.id, s.media_url;
END;
$$;

-- ── Grants : SECURITY DEFINER sensibles = service_role uniquement ────────────
REVOKE ALL ON FUNCTION public.increment_story_view(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.purge_expired_stories()          FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.increment_story_view(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.purge_expired_stories()          TO service_role;
