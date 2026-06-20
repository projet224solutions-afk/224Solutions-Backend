-- ============================================================================
-- STOCKAGE — FORCER les buckets d'images en PUBLIC + politiques permissives.
-- ----------------------------------------------------------------------------
-- Symptôme : « aucune image ne s'affiche après upload, partout ». Cause typique :
-- les buckets existent mais ne sont PAS publics (créés en privé, jamais repassés
-- public car les anciens INSERT utilisaient ON CONFLICT DO NOTHING). L'URL publique
-- renvoie alors 400/403 → image cassée. Ici on FORCE public=true + lecture publique
-- + upload authentifié. Idempotent.
-- ============================================================================

-- 1) Forcer public = true sur les buckets d'images/medias (les crée s'ils manquent).
INSERT INTO storage.buckets (id, name, public) VALUES
  ('restaurant-assets',   'restaurant-assets',   true),
  ('product-images',      'product-images',      true),
  ('communication-files', 'communication-files', true),
  ('avatars',             'avatars',             true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- 2) Lecture PUBLIQUE (affichage des images) + upload AUTHENTIFIÉ, par bucket.
--    Politiques idempotentes (DROP puis CREATE).

-- restaurant-assets (bucket d'images des services : beauté, agriculture, portfolio…)
DROP POLICY IF EXISTS ra_public_read   ON storage.objects;
CREATE POLICY ra_public_read   ON storage.objects FOR SELECT TO public        USING (bucket_id = 'restaurant-assets');
DROP POLICY IF EXISTS ra_auth_insert   ON storage.objects;
CREATE POLICY ra_auth_insert   ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'restaurant-assets');
DROP POLICY IF EXISTS ra_auth_update   ON storage.objects;
CREATE POLICY ra_auth_update   ON storage.objects FOR UPDATE TO authenticated USING (bucket_id = 'restaurant-assets');

-- communication-files (vidéos + fichiers)
DROP POLICY IF EXISTS cf_public_read   ON storage.objects;
CREATE POLICY cf_public_read   ON storage.objects FOR SELECT TO public        USING (bucket_id = 'communication-files');
DROP POLICY IF EXISTS cf_auth_insert   ON storage.objects;
CREATE POLICY cf_auth_insert   ON storage.objects FOR INSERT TO authenticated WITH CHECK (bucket_id = 'communication-files');

-- product-images (lecture publique garantie ; l'upload garde ses politiques existantes)
DROP POLICY IF EXISTS pi_public_read   ON storage.objects;
CREATE POLICY pi_public_read   ON storage.objects FOR SELECT TO public        USING (bucket_id = 'product-images');

SELECT 'Buckets d''images forcés en public + politiques lecture/upload garanties.' AS status,
       (SELECT json_agg(json_build_object('id', id, 'public', public)) FROM storage.buckets
        WHERE id IN ('restaurant-assets','product-images','communication-files','avatars')) AS buckets;
