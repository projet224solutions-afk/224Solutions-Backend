-- Supprimer la politique trop restrictive
DROP POLICY IF EXISTS "Authenticated users can upload files" ON storage.objects;

-- Créer des politiques plus flexibles pour différents types de uploads

-- Politique pour les documents de motos
CREATE POLICY "Authenticated users can upload moto documents"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'product-images' 
  AND (storage.foldername(name))[1] = 'moto-documents'
);

-- Politique pour les photos de motos
CREATE POLICY "Authenticated users can upload moto files"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'product-images' 
  AND (storage.foldername(name))[1] = 'motos'
);