-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATAIRE — Scanner OCR (notes) + Studio de documents (modèles + champs)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Notes scannées (texte extrait par vision IA, MODIFIABLE, attachable à un devis)
CREATE TABLE IF NOT EXISTS public.provider_scanned_notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL,
  title text NOT NULL DEFAULT 'Document scanné',
  content text NOT NULL DEFAULT '',
  source_image_url text,
  quote_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT content_len CHECK (length(content) <= 20000)
);
CREATE INDEX IF NOT EXISTS idx_psn_provider ON public.provider_scanned_notes(provider_user_id, created_at DESC);
ALTER TABLE public.provider_scanned_notes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS psn_owner ON public.provider_scanned_notes;
CREATE POLICY psn_owner ON public.provider_scanned_notes FOR ALL
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- Documents du Studio (design + champs jsonb, ré-ouvrable/modifiable/duplicable)
CREATE TABLE IF NOT EXISTS public.provider_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL,
  category text NOT NULL,
  template_id text NOT NULL,
  title text NOT NULL DEFAULT 'Document',
  client_name text,
  fields jsonb NOT NULL DEFAULT '{}'::jsonb,
  quote_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pdoc_provider ON public.provider_documents(provider_user_id, created_at DESC);
ALTER TABLE public.provider_documents ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pdoc_owner ON public.provider_documents;
CREATE POLICY pdoc_owner ON public.provider_documents FOR ALL
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());

-- Modèles PERSONNELS du prestataire (valeurs par défaut réutilisables)
CREATE TABLE IF NOT EXISTS public.provider_document_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL,
  category text NOT NULL,
  template_id text NOT NULL,
  name text NOT NULL,
  fields jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.provider_document_templates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pdt_owner ON public.provider_document_templates;
CREATE POLICY pdt_owner ON public.provider_document_templates FOR ALL
  USING (provider_user_id = auth.uid()) WITH CHECK (provider_user_id = auth.uid());
