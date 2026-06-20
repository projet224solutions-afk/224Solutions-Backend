-- Créer un bucket public pour les fichiers d'installation (APK, EXE)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'app-downloads',
  'app-downloads',
  true,
  104857600, -- 100MB max
  ARRAY['application/vnd.android.package-archive', 'application/x-msdownload', 'application/octet-stream']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = true,
  file_size_limit = 104857600;

-- Politique de lecture publique (tout le monde peut télécharger)
CREATE POLICY "Public can download app files"
ON storage.objects FOR SELECT
USING (bucket_id = 'app-downloads');

-- Politique d'upload réservée aux admins (CEO ou admin)
CREATE POLICY "Only admins can upload app files"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'app-downloads' 
  AND EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role IN ('admin', 'ceo')
  )
);

-- Politique de suppression réservée aux admins
CREATE POLICY "Only admins can delete app files"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'app-downloads' 
  AND EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role IN ('admin', 'ceo')
  )
);