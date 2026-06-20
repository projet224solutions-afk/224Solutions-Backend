-- Créer le bucket kyc-documents pour les documents de vérification KYC
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'kyc-documents', 
  'kyc-documents', 
  false,  -- Privé pour la sécurité des documents d'identité
  5242880, -- 5 Mo max
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO NOTHING;

-- Politique RLS: Les vendeurs peuvent uploader leurs propres documents
CREATE POLICY "Vendors can upload their own KYC documents"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'kyc-documents' AND
  (storage.foldername(name))[1] = auth.uid()::text
);

-- Politique RLS: Les vendeurs peuvent voir leurs propres documents
CREATE POLICY "Vendors can view their own KYC documents"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'kyc-documents' AND
  (storage.foldername(name))[1] = auth.uid()::text
);

-- Politique RLS: Les vendeurs peuvent supprimer leurs propres documents
CREATE POLICY "Vendors can delete their own KYC documents"
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'kyc-documents' AND
  (storage.foldername(name))[1] = auth.uid()::text
);

-- Politique pour que les admins (PDG) puissent accéder à tous les documents KYC
CREATE POLICY "Admins can access all KYC documents"
ON storage.objects
FOR ALL
TO authenticated
USING (
  bucket_id = 'kyc-documents' AND
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role::text IN ('admin', 'pdg')
  )
)
WITH CHECK (
  bucket_id = 'kyc-documents' AND
  EXISTS (
    SELECT 1 FROM profiles 
    WHERE id = auth.uid() 
    AND role::text IN ('admin', 'pdg')
  )
);