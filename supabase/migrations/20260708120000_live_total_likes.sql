-- ============================================================================
-- Live Shopping — total de likes PERSISTÉ par live (coeurs).
-- Aujourd'hui les réactions coeur sont éphémères (canal temps réel) + une ligne
-- d'audit dans live_stream_events(event_type='reaction'). Le compteur repart de 0
-- à chaque ouverture. On persiste un total O(1) lisible publiquement.
--
-- Choix : colonne dénormalisée total_likes sur live_streams (héritant de la policy
-- publique live_streams_public_read) plutôt que COUNT(*) dérivé — car la lecture de
-- live_stream_events est réservée au host+admin (les spectateurs/anon ne peuvent PAS
-- la lire) et les endpoints listent jusqu'à 50 lives (un agrégat par live serait N).
-- live_stream_events reste la source d'audit reconciliable.
--
-- Incrément STRICTEMENT atomique côté DB (total_likes = total_likes + 1) via trigger
-- AFTER INSERT — jamais de lecture-puis-écriture côté client.
-- ============================================================================

-- 1) Colonne dénormalisée
ALTER TABLE public.live_streams
  ADD COLUMN IF NOT EXISTS total_likes int NOT NULL DEFAULT 0;

-- 2) Backfill des lives existants depuis l'audit
UPDATE public.live_streams s
SET total_likes = COALESCE((
  SELECT count(*) FROM public.live_stream_events e
  WHERE e.live_stream_id = s.id AND e.event_type = 'reaction'
), 0)
WHERE s.total_likes = 0;

-- 3) Fonction trigger : incrément atomique. SECURITY DEFINER car l'inséreur
--    authentifié (un spectateur) n'a pas le droit d'UPDATE live_streams d'un
--    autre vendeur (policy vendor_user_id = auth.uid()).
CREATE OR REPLACE FUNCTION public.increment_live_total_likes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.live_streams
  SET total_likes = total_likes + 1
  WHERE id = NEW.live_stream_id;
  RETURN NEW;
END;
$$;

-- Fonction trigger : jamais appelable via PostgREST.
REVOKE ALL ON FUNCTION public.increment_live_total_likes() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.increment_live_total_likes() FROM anon;
REVOKE ALL ON FUNCTION public.increment_live_total_likes() FROM authenticated;

-- 4) Trigger : uniquement sur les réactions coeur
DROP TRIGGER IF EXISTS trg_live_reaction_like ON public.live_stream_events;
CREATE TRIGGER trg_live_reaction_like
  AFTER INSERT ON public.live_stream_events
  FOR EACH ROW
  WHEN (NEW.event_type = 'reaction')
  EXECUTE FUNCTION public.increment_live_total_likes();

-- RLS inchangée : la lecture publique de total_likes est couverte par la policy
-- existante live_streams_public_read ; l'insert 'reaction' reste TO authenticated
-- (live_events_auth_insert). Aucune nouvelle surface exposée.
