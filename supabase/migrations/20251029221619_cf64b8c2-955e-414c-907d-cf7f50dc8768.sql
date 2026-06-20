
-- Supprimer l'ancienne politique qui pose problème
DROP POLICY IF EXISTS "Allow authenticated uploads" ON storage.objects;

-- Créer une politique claire pour les uploads dans product-images
CREATE POLICY "Authenticated users can upload to product-images"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'product-images');

-- S'assurer que les utilisateurs authentifiés peuvent uploader dans communication-files
CREATE POLICY "Authenticated users can upload to communication-files"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'communication-files');
