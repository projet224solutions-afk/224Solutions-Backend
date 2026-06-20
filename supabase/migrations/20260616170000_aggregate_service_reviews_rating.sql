-- ============================================================================
-- AGRÉGATION NOTE & NOMBRE D'AVIS : service_reviews → professional_services.
-- Les avis (NOTER côté client) étaient stockés dans service_reviews mais JAMAIS agrégés
-- vers professional_services.rating / total_reviews → la carte marketplace affichait
-- toujours 0 / « Nouveau » même avec des avis réels. On pose un trigger qui recalcule
-- la moyenne + le compte à chaque insertion/màj/suppression d'avis, + un backfill.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recompute_service_rating()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sid uuid := COALESCE(NEW.professional_service_id, OLD.professional_service_id);
BEGIN
  IF v_sid IS NULL THEN RETURN COALESCE(NEW, OLD); END IF;
  UPDATE public.professional_services ps
  SET rating        = COALESCE((SELECT ROUND(AVG(rating)::numeric, 1) FROM public.service_reviews WHERE professional_service_id = v_sid), 0),
      total_reviews = (SELECT COUNT(*) FROM public.service_reviews WHERE professional_service_id = v_sid),
      updated_at    = now()
  WHERE ps.id = v_sid;
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS trg_recompute_service_rating ON public.service_reviews;
CREATE TRIGGER trg_recompute_service_rating
  AFTER INSERT OR UPDATE OR DELETE ON public.service_reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.recompute_service_rating();

-- Backfill : aligne tous les services sur leurs avis existants.
UPDATE public.professional_services ps
SET rating        = COALESCE(sub.avg_r, 0),
    total_reviews = COALESCE(sub.cnt, 0)
FROM (
  SELECT professional_service_id, ROUND(AVG(rating)::numeric, 1) AS avg_r, COUNT(*) AS cnt
  FROM public.service_reviews
  GROUP BY professional_service_id
) sub
WHERE ps.id = sub.professional_service_id;

SELECT 'Notes agrégées : trigger service_reviews → professional_services.rating/total_reviews + backfill.' AS status;
