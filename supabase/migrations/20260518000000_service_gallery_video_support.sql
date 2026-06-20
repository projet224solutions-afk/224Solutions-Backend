-- ================================================================
-- Service Gallery — Support vidéos multi-médias (2026-05-18)
--
-- Étend service_gallery_images pour accueillir images ET vidéos :
--   media_type : 'image' (défaut) ou 'video'
--   video_url  : URL de la vidéo (bucket service-gallery-videos)
--   thumbnail_url : miniature générée ou uploadée pour la vidéo
--
-- Le bucket service-gallery (images) existait déjà.
-- Création du bucket service-gallery-videos pour les vidéos.
-- ================================================================

-- 1. Ajouter les colonnes médias manquantes
ALTER TABLE public.service_gallery_images
  ADD COLUMN IF NOT EXISTS media_type   TEXT    NOT NULL DEFAULT 'image'
                                        CHECK (media_type IN ('image', 'video')),
  ADD COLUMN IF NOT EXISTS video_url    TEXT,
  ADD COLUMN IF NOT EXISTS thumbnail_url TEXT;

-- 2. Créer le bucket pour les vidéos (public, max 100 MB)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'service-gallery-videos',
  'service-gallery-videos',
  true,
  104857600, -- 100 MB
  ARRAY['video/mp4', 'video/webm', 'video/quicktime', 'video/x-msvideo']
)
ON CONFLICT (id) DO NOTHING;

-- 3. Politiques RLS pour service-gallery-videos
-- Lecture publique
CREATE POLICY "service_gallery_videos_public_read"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'service-gallery-videos');

-- Upload par propriétaire du service (via user_id dans le path)
CREATE POLICY "service_gallery_videos_owner_insert"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'service-gallery-videos'
    AND auth.uid() IS NOT NULL
  );

CREATE POLICY "service_gallery_videos_owner_delete"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'service-gallery-videos'
    AND auth.uid() IS NOT NULL
  );

-- 4. Politique RLS étendue sur service_gallery_images
--    (les politiques existantes couvrent images, on s'assure qu'elles couvrent aussi vidéos)
DROP POLICY IF EXISTS "service_gallery_images_owner_manage" ON public.service_gallery_images;

CREATE POLICY "service_gallery_images_owner_manage"
  ON public.service_gallery_images
  FOR ALL
  USING (
    professional_service_id IN (
      SELECT id FROM public.professional_services WHERE user_id = auth.uid()
    )
  )
  WITH CHECK (
    professional_service_id IN (
      SELECT id FROM public.professional_services WHERE user_id = auth.uid()
    )
  );

SELECT 'service_gallery_images — support vidéo ajouté (media_type, video_url, thumbnail_url).' AS status;
