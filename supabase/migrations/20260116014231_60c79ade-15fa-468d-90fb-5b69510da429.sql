-- Créer le bucket pour les vidéos produits (Premium uniquement)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'product-videos',
  'product-videos',
  true,
  104857600, -- 100MB max
  ARRAY['video/mp4', 'video/webm', 'video/quicktime', 'video/x-msvideo']
);

-- Policy: Lecture publique
CREATE POLICY "Product videos are publicly accessible"
ON storage.objects FOR SELECT
USING (bucket_id = 'product-videos');

-- Policy: Upload uniquement par vendeurs authentifiés
CREATE POLICY "Vendors can upload product videos"
ON storage.objects FOR INSERT
WITH CHECK (
  bucket_id = 'product-videos' 
  AND auth.role() = 'authenticated'
);

-- Policy: Vendeurs peuvent supprimer leurs propres vidéos
CREATE POLICY "Vendors can delete their own videos"
ON storage.objects FOR DELETE
USING (
  bucket_id = 'product-videos' 
  AND auth.role() = 'authenticated'
  AND (storage.foldername(name))[1] IN (
    SELECT id::text FROM vendors WHERE user_id = auth.uid()
  )
);

-- Policy: Vendeurs peuvent mettre à jour leurs propres vidéos
CREATE POLICY "Vendors can update their own videos"
ON storage.objects FOR UPDATE
USING (
  bucket_id = 'product-videos' 
  AND auth.role() = 'authenticated'
  AND (storage.foldername(name))[1] IN (
    SELECT id::text FROM vendors WHERE user_id = auth.uid()
  )
);