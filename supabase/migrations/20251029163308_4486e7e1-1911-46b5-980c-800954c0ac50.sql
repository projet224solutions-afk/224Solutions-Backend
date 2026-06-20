-- Supprimer les politiques trop restrictives
DROP POLICY IF EXISTS "Authenticated users can upload moto documents" ON storage.objects;
DROP POLICY IF EXISTS "Authenticated users can upload moto files" ON storage.objects;

-- Créer une politique plus simple et permissive pour les utilisateurs authentifiés
CREATE POLICY "Authenticated users can upload to product-images"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'product-images');