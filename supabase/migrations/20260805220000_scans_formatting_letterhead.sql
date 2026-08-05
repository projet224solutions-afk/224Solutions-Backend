-- ============================================================================
-- ✒️ SCANS — mise en forme des notes + papier à en-tête + import PDF/Word
-- 1) provider_scanned_notes.formatting : mise en forme persistée (police/taille/
--    alignement par note ou par paragraphe, en-tête on/off, cadre, pied, numéros).
-- 2) provider_scanned_notes.source / source_file_url : notes importées de PDF/.docx
--    (une SEULE liste de notes, badge de source ; le fichier d'origine reste consultable).
-- 3) provider_letterhead : en-tête professionnel configuré UNE FOIS (logo, nom, tél,
--    adresse, ville, email) + mise en forme PAR DÉFAUT des nouvelles notes. RLS owner.
-- ============================================================================

ALTER TABLE public.provider_scanned_notes
  ADD COLUMN IF NOT EXISTS formatting jsonb,
  ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'photo'
    CHECK (source IN ('photo', 'pdf', 'docx')),
  ADD COLUMN IF NOT EXISTS source_file_url text CHECK (char_length(source_file_url) <= 1000);

CREATE TABLE IF NOT EXISTS public.provider_letterhead (
  provider_user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  logo_url text CHECK (char_length(logo_url) <= 1000),
  business_name text CHECK (char_length(business_name) <= 200),
  phone text CHECK (char_length(phone) <= 50),
  address text CHECK (char_length(address) <= 300),
  city text CHECK (char_length(city) <= 100),
  email text CHECK (char_length(email) <= 200),
  default_formatting jsonb,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.provider_letterhead ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS letterhead_owner_all ON public.provider_letterhead;
CREATE POLICY letterhead_owner_all ON public.provider_letterhead
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid())
  WITH CHECK (provider_user_id = auth.uid());
