-- ============================================================================
-- PAYWALL VIDÉO — ENFORCEMENT CÔTÉ BASE (anti-contournement).
--
-- Avant : le verrou « vidéo = abonnement Premium » n'existait QU'EN FRONTEND
-- (boutons grisés). Le RLS de service_gallery_images / service_showcase autorise
-- le propriétaire à TOUT écrire (FOR ALL) → un service au plan GRATUIT pouvait
-- publier des vidéos par simple appel API (DevTools/script), contournant le
-- paywall (40 000–150 000 GNF/mois selon le type de service) = perte de revenu.
--
-- Fix : un trigger BEFORE INSERT/UPDATE REJETTE toute ligne vidéo (video_url non
-- nul) si le service n'a pas le droit vidéo (abonnement ACTIF + plan can_upload_video).
-- Source de vérité unique = le flag can_upload_video du plan (même règle que la RPC
-- get_service_subscription). Le backend (service_role, auth.uid() NULL) est exempté.
-- ============================================================================

-- Droit vidéo d'un service = abonnement actif non expiré sur un plan can_upload_video.
CREATE OR REPLACE FUNCTION public.service_can_upload_video(p_service_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.service_subscriptions ss
    JOIN public.service_plans sp ON sp.id = ss.plan_id
    WHERE ss.professional_service_id = p_service_id
      AND ss.status = 'active'
      AND ss.current_period_end > now()
      AND COALESCE(sp.can_upload_video, false) = true
  );
$$;

REVOKE ALL ON FUNCTION public.service_can_upload_video(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.service_can_upload_video(uuid) TO authenticated, service_role;

-- Trigger commun aux deux galeries : toute ligne portant une video_url exige le droit vidéo.
-- (Une vidéo a toujours video_url renseigné ; les photos ont video_url NULL → jamais bloquées.)
CREATE OR REPLACE FUNCTION public.enforce_video_premium()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.video_url IS NOT NULL THEN
    -- Backend de confiance (service_role) : auth.uid() est NULL → on laisse passer.
    -- Les clients (authenticated) ont toujours un auth.uid() → soumis au paywall.
    IF auth.uid() IS NOT NULL AND NOT public.service_can_upload_video(NEW.professional_service_id) THEN
      RAISE EXCEPTION 'VIDEO_PREMIUM_REQUIS'
        USING HINT = 'L''ajout de vidéos nécessite un abonnement Premium actif. Les photos restent gratuites.';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- Galerie médias (service_gallery_images).
DROP TRIGGER IF EXISTS trg_enforce_video_premium_gallery ON public.service_gallery_images;
CREATE TRIGGER trg_enforce_video_premium_gallery
  BEFORE INSERT OR UPDATE ON public.service_gallery_images
  FOR EACH ROW EXECUTE FUNCTION public.enforce_video_premium();

-- Vitrine marketplace (service_showcase).
DROP TRIGGER IF EXISTS trg_enforce_video_premium_showcase ON public.service_showcase;
CREATE TRIGGER trg_enforce_video_premium_showcase
  BEFORE INSERT OR UPDATE ON public.service_showcase
  FOR EACH ROW EXECUTE FUNCTION public.enforce_video_premium();

SELECT 'Paywall vidéo verrouillé en base : trigger enforce_video_premium sur service_gallery_images + service_showcase.' AS status;
