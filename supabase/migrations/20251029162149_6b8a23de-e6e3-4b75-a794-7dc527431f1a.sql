-- Créer les politiques RLS pour le bucket product-images
-- Permettre aux utilisateurs authentifiés de télécharger des fichiers

-- Politique pour INSERT (upload)
CREATE POLICY "Authenticated users can upload files"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'product-images');

-- Politique pour SELECT (read/download)
CREATE POLICY "Public can view product images"
ON storage.objects
FOR SELECT
TO public
USING (bucket_id = 'product-images');

-- Politique pour UPDATE
CREATE POLICY "Authenticated users can update their files"
ON storage.objects
FOR UPDATE
TO authenticated
USING (bucket_id = 'product-images')
WITH CHECK (bucket_id = 'product-images');

-- Politique pour DELETE
CREATE POLICY "Authenticated users can delete their files"
ON storage.objects
FOR DELETE
TO authenticated
USING (bucket_id = 'product-images');