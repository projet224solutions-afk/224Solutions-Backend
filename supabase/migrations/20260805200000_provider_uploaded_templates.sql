-- ============================================================================
-- 📁 BIBLIOTHÈQUE PERSONNELLE DE MODÈLES TÉLÉVERSÉS (Studio de documents)
-- Le prestataire téléverse SES propres modèles (.docx, images, PDF — potentiellement
-- des milliers) : dossiers/tags/recherche/pagination côté client, quota 2 Go par
-- utilisateur (blindé par trigger), RLS propriétaire strict.
-- `variable_indexes` = GABARIT : clés des paragraphes modifiés lors des réutilisations
-- .docx → à la prochaine réutilisation, seuls ces champs sont montrés (<1 min).
-- L'ORIGINAL n'est JAMAIS modifié : chaque réutilisation régénère une COPIE.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.provider_uploaded_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 200),
  file_url text NOT NULL CHECK (char_length(file_url) <= 1000),
  -- objet storage (pour suppression GCS/Supabase) + provider ('gcs'|'supabase')
  object_path text CHECK (char_length(object_path) <= 500),
  storage_provider text CHECK (storage_provider IN ('gcs', 'supabase')),
  storage_bucket text CHECK (char_length(storage_bucket) <= 100),
  file_type text NOT NULL CHECK (file_type IN ('docx', 'image', 'pdf')),
  mime_type text CHECK (char_length(mime_type) <= 150),
  size_bytes bigint NOT NULL DEFAULT 0 CHECK (size_bytes >= 0 AND size_bytes <= 10 * 1024 * 1024), -- 10 Mo / fichier
  folder text NOT NULL DEFAULT '' CHECK (char_length(folder) <= 100),
  tags text[] NOT NULL DEFAULT '{}' CHECK (array_length(tags, 1) IS NULL OR array_length(tags, 1) <= 20),
  variable_indexes jsonb, -- gabarit : clés (fichier#paragraphe) des textes qui changent
  last_used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Recherche/pagination : liste par propriétaire (récent d'abord), filtre dossier.
CREATE INDEX IF NOT EXISTS idx_put_owner_created
  ON public.provider_uploaded_templates (provider_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_put_owner_folder
  ON public.provider_uploaded_templates (provider_user_id, folder);

ALTER TABLE public.provider_uploaded_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS put_owner_all ON public.provider_uploaded_templates;
CREATE POLICY put_owner_all ON public.provider_uploaded_templates
  FOR ALL TO authenticated
  USING (provider_user_id = auth.uid())
  WITH CHECK (provider_user_id = auth.uid());

-- ── Quota 2 Go / utilisateur, blindé côté DB (le front l'affiche ET le vérifie,
--    mais seul le trigger est infalsifiable). ──
CREATE OR REPLACE FUNCTION public.enforce_uploaded_templates_quota()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total bigint;
  v_quota constant bigint := 2 * 1024 * 1024 * 1024; -- 2 Go
BEGIN
  SELECT COALESCE(SUM(size_bytes), 0) INTO v_total
  FROM public.provider_uploaded_templates
  WHERE provider_user_id = NEW.provider_user_id
    AND (TG_OP = 'INSERT' OR id <> NEW.id);
  IF v_total + NEW.size_bytes > v_quota THEN
    RAISE EXCEPTION 'STORAGE_QUOTA_EXCEEDED: % + % > 2 Go', v_total, NEW.size_bytes;
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_put_quota ON public.provider_uploaded_templates;
CREATE TRIGGER trg_put_quota
  BEFORE INSERT OR UPDATE ON public.provider_uploaded_templates
  FOR EACH ROW EXECUTE FUNCTION public.enforce_uploaded_templates_quota();

-- ── Usage total du quota (affichage front) — l'appelant est vérifié DANS la fonction
--    (filtre auth.uid()), pas d'accès anon. ──
CREATE OR REPLACE FUNCTION public.get_uploaded_templates_usage()
RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(SUM(size_bytes), 0)::bigint
  FROM public.provider_uploaded_templates
  WHERE provider_user_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION public.get_uploaded_templates_usage() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_uploaded_templates_usage() TO authenticated;
