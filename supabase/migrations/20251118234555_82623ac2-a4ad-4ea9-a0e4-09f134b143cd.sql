-- Créer le bucket de stockage pour les documents (devis/factures)
INSERT INTO storage.buckets (id, name, public)
VALUES ('documents', 'documents', true)
ON CONFLICT (id) DO NOTHING;

-- Politique pour permettre l'upload des documents par les vendeurs authentifiés
CREATE POLICY "Vendors can upload documents"
ON storage.objects
FOR INSERT
WITH CHECK (
  bucket_id = 'documents' AND
  auth.role() = 'authenticated'
);

-- Politique pour permettre la lecture publique des documents
CREATE POLICY "Public can view documents"
ON storage.objects
FOR SELECT
USING (bucket_id = 'documents');

-- Politique pour permettre aux vendeurs de supprimer leurs propres documents
CREATE POLICY "Vendors can delete their documents"
ON storage.objects
FOR DELETE
USING (
  bucket_id = 'documents' AND
  auth.role() = 'authenticated'
);