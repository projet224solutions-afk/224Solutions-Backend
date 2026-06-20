-- ============================================================================
-- MÉDIAS SERVICES (PHASE 3) — vidéo (réservée au plan Premium) + vitrine publiable.
-- ----------------------------------------------------------------------------
-- - beauty_services.video_url : vidéo de présentation (upload gardé côté UI au Premium).
-- - service_showcase : « vitrine » publiable au marketplace pour les services SANS
--   catalogue (Sport, Ménage…) — image + vidéo (Premium) + prix indicatif.
-- Lecture publique des items actifs (pour le marketplace). Rejouable.
-- ============================================================================

ALTER TABLE public.beauty_services ADD COLUMN IF NOT EXISTS video_url text;

CREATE TABLE IF NOT EXISTS public.service_showcase (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  title                   text NOT NULL,
  description             text,
  image_url               text,
  video_url               text,
  price                   numeric(12,2) NOT NULL DEFAULT 0,
  category                text,
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_service_showcase_service ON public.service_showcase (professional_service_id, is_active);

ALTER TABLE public.service_showcase ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS showcase_owner ON public.service_showcase;
CREATE POLICY showcase_owner ON public.service_showcase
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS showcase_public_read ON public.service_showcase;
CREATE POLICY showcase_public_read ON public.service_showcase FOR SELECT USING (is_active = true);

SELECT 'Médias services : beauty_services.video_url + table service_showcase (vitrine publiable).' AS status;
