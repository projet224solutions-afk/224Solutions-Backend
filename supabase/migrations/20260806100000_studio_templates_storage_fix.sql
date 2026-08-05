-- ============================================================================
-- 📁 BIBLIOTHÈQUE STUDIO — storage propre + vignettes (audit 06/08/2026)
-- 1) preview_url : vignette du modèle (image compressée / 1re page PDF).
-- 2) Bucket Supabase DÉDIÉ `studio-templates` (PRIVÉ) pour le fallback — fini
--    l'atterrissage dans `communication-files` (bucket de la messagerie).
--    Policies owner-only par préfixe de chemin : {userId}/... ; la lecture passe
--    par le PROXY backend (service_role) → pas besoin de bucket public, pas de CORS.
-- ============================================================================

ALTER TABLE public.provider_uploaded_templates
  ADD COLUMN IF NOT EXISTS preview_url text CHECK (char_length(preview_url) <= 1000);

INSERT INTO storage.buckets (id, name, public)
VALUES ('studio-templates', 'studio-templates', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS studio_tpl_owner_insert ON storage.objects;
CREATE POLICY studio_tpl_owner_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'studio-templates' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS studio_tpl_owner_select ON storage.objects;
CREATE POLICY studio_tpl_owner_select ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'studio-templates' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS studio_tpl_owner_delete ON storage.objects;
CREATE POLICY studio_tpl_owner_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'studio-templates' AND (storage.foldername(name))[1] = auth.uid()::text);
