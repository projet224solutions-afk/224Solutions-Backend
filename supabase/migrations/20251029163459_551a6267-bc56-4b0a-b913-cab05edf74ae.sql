-- Supprimer TOUTES les politiques INSERT existantes pour éviter les conflits
DROP POLICY IF EXISTS "Authenticated users can upload to product-images" ON storage.objects;
DROP POLICY IF EXISTS "Users can upload files to their conversations" ON storage.objects;
DROP POLICY IF EXISTS "Vendors can upload product images" ON storage.objects;

-- Créer UNE politique INSERT simple et permissive pour tous les buckets
CREATE POLICY "Allow authenticated uploads"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (true);