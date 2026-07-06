-- ============================================================================
-- Stories = REPLAY partagé (correction de cap).
-- Une story peut désormais RÉFÉRENCER un replay (live_stream_id) : le vendeur partage
-- SON replay en story ; cliquer la story redirige DIRECTEMENT vers /live/replay/:id.
-- media_url/media_type/thumbnail restent dérivés du replay (rétro-compat média libre).
--
-- CHOIX DOCUMENTÉ (durée) : la story-replay reste une story 24h (barre ronde en haut).
-- La visibilité PERMANENTE du replay sur le profil boutique est assurée séparément par
-- une grille « Replays de la boutique » (ReplayGrid filtré par vendor) — pas d'allongement
-- de l'expiration des stories.
--
-- Écriture inchangée : 100% backend (service_role). La route vérifie que le live
-- appartient au vendeur (live_streams.vendor_user_id = userId) avant de créer la story.
-- ============================================================================

ALTER TABLE public.vendor_stories
  ADD COLUMN IF NOT EXISTS live_stream_id uuid REFERENCES public.live_streams(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_vendor_stories_live ON public.vendor_stories(live_stream_id);
