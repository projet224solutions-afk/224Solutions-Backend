-- =====================================================
-- STORAGE BUCKET POUR DOCUMENTS GÉNÉRÉS PAR L'IA
-- =====================================================

-- Créer le bucket pour les documents AI
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'ai-documents',
  'ai-documents',
  true,
  52428800, -- 50MB max
  ARRAY['application/pdf', 'application/json', 'text/html', 'text/plain']
)
ON CONFLICT (id) DO NOTHING;

-- =====================================================
-- POLITIQUES RLS POUR LE BUCKET AI-DOCUMENTS
-- =====================================================

-- Politique: Les utilisateurs authentifiés peuvent voir leurs propres documents
CREATE POLICY "Users can view their own AI documents"
ON storage.objects
FOR SELECT
USING (
  bucket_id = 'ai-documents'
  AND auth.uid()::text = (storage.foldername(name))[1]
);

-- Politique: Les utilisateurs authentifiés peuvent télécharger leurs propres documents  
CREATE POLICY "Users can download their own AI documents"
ON storage.objects
FOR SELECT
USING (
  bucket_id = 'ai-documents'
  AND (
    auth.uid()::text = (storage.foldername(name))[1]
    OR (storage.foldername(name))[1] = 'public'
  )
);

-- Politique: Le service peut uploader des documents
CREATE POLICY "Service can upload AI documents"
ON storage.objects
FOR INSERT
WITH CHECK (bucket_id = 'ai-documents');

-- Politique: Le service peut supprimer des documents
CREATE POLICY "Service can delete AI documents"
ON storage.objects
FOR DELETE
USING (bucket_id = 'ai-documents');

-- =====================================================
-- TABLE DE SUIVI DES DOCUMENTS AI GÉNÉRÉS
-- =====================================================

CREATE TABLE IF NOT EXISTS public.ai_generated_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  vendor_id UUID,
  document_type VARCHAR(100) NOT NULL,
  document_title VARCHAR(500) NOT NULL,
  file_path TEXT NOT NULL,
  file_url TEXT NOT NULL,
  file_size_bytes BIGINT,
  language VARCHAR(10) DEFAULT 'fr',
  generation_source VARCHAR(100) DEFAULT 'vendor-ai-assistant',
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  expires_at TIMESTAMP WITH TIME ZONE,
  download_count INTEGER DEFAULT 0,
  last_downloaded_at TIMESTAMP WITH TIME ZONE
);

-- Index pour recherche rapide
CREATE INDEX IF NOT EXISTS idx_ai_documents_user ON ai_generated_documents(user_id);
CREATE INDEX IF NOT EXISTS idx_ai_documents_vendor ON ai_generated_documents(vendor_id);
CREATE INDEX IF NOT EXISTS idx_ai_documents_type ON ai_generated_documents(document_type);
CREATE INDEX IF NOT EXISTS idx_ai_documents_created ON ai_generated_documents(created_at DESC);

-- Activer RLS
ALTER TABLE public.ai_generated_documents ENABLE ROW LEVEL SECURITY;

-- Politique: Les utilisateurs peuvent voir leurs propres documents
CREATE POLICY "Users can view their own generated documents"
ON public.ai_generated_documents
FOR SELECT
USING (auth.uid() = user_id);

-- Politique: Insertion par le système (service role)
CREATE POLICY "System can insert generated documents"
ON public.ai_generated_documents
FOR INSERT
WITH CHECK (true);

-- Politique: Les utilisateurs peuvent supprimer leurs propres documents
CREATE POLICY "Users can delete their own generated documents"
ON public.ai_generated_documents
FOR DELETE
USING (auth.uid() = user_id);

-- Fonction pour incrémenter le compteur de téléchargement
CREATE OR REPLACE FUNCTION public.increment_document_download(doc_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE ai_generated_documents
  SET 
    download_count = download_count + 1,
    last_downloaded_at = NOW()
  WHERE id = doc_id;
END;
$$;