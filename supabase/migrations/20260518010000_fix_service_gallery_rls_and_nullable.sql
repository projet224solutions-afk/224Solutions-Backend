-- ================================================================
-- FIX service_gallery_images — 3 bugs (2026-05-18)
--
-- Bug 1 : image_url NOT NULL bloque l'insert de vidéos
--         (les vidéos n'ont pas d'image_url) → rendre nullable
--
-- Bug 2 : RLS non configuré sur service_gallery_images
--         → activer RLS + policies lecture publique + écriture propriétaire
--
-- Bug 3 : cover_image_url dans professional_services non mis à jour
--         → géré côté frontend (ServiceMediaManager.tsx)
-- ================================================================

-- 1. Rendre image_url nullable (les vidéos n'ont pas d'image_url)
ALTER TABLE public.service_gallery_images
  ALTER COLUMN image_url DROP NOT NULL;

-- 2. Activer RLS
ALTER TABLE public.service_gallery_images ENABLE ROW LEVEL SECURITY;

-- 3. Lecture publique (tout le monde peut voir les médias d'un service)
DROP POLICY IF EXISTS "service_gallery_public_read" ON public.service_gallery_images;
CREATE POLICY "service_gallery_public_read"
  ON public.service_gallery_images
  FOR SELECT
  USING (true);

-- 4. Gestion complète par le propriétaire du service
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

-- 5. Le service_role (backend) peut tout faire
DROP POLICY IF EXISTS "service_gallery_service_role" ON public.service_gallery_images;
CREATE POLICY "service_gallery_service_role"
  ON public.service_gallery_images
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

SELECT 'service_gallery_images — image_url nullable + RLS activé + policies créées.' AS status;
