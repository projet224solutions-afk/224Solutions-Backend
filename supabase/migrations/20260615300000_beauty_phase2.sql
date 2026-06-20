-- ============================================================================
-- BEAUTÉ — PHASE 2 : forfaits + galerie avant/après + consentement numérique.
-- ----------------------------------------------------------------------------
-- - beauty_packages         : forfaits (plusieurs services, durée cumulée, prix remisé).
-- - beauty_gallery          : réalisations avant/après (publiques OU privées par client).
-- - beauty_consent_forms    : modèles de formulaires de consentement (soins chimiques).
-- - beauty_consent_signatures : signatures électroniques liées à un RDV.
-- RLS owner + lecture publique des éléments publics. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.beauty_packages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  service_ids uuid[] NOT NULL DEFAULT '{}',
  total_duration_minutes integer NOT NULL DEFAULT 0,
  price numeric(10,2) NOT NULL DEFAULT 0,
  original_price numeric(10,2) NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_beauty_packages_service ON public.beauty_packages (professional_service_id, is_active);

CREATE TABLE IF NOT EXISTS public.beauty_gallery (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  client_user_id uuid REFERENCES auth.users(id),       -- si privé : lié à ce client
  before_url text,
  after_url text,
  image_url text,                                      -- réalisation simple
  service_category text,
  description text,
  is_public boolean NOT NULL DEFAULT true,
  is_pinned boolean NOT NULL DEFAULT false,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_beauty_gallery_service ON public.beauty_gallery (professional_service_id, is_public);

CREATE TABLE IF NOT EXISTS public.beauty_consent_forms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  title text NOT NULL,
  content text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_beauty_consent_service ON public.beauty_consent_forms (professional_service_id);

CREATE TABLE IF NOT EXISTS public.beauty_consent_signatures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  form_id uuid NOT NULL REFERENCES public.beauty_consent_forms(id) ON DELETE CASCADE,
  appointment_id uuid REFERENCES public.beauty_appointments(id) ON DELETE SET NULL,
  client_user_id uuid REFERENCES auth.users(id),
  signature_url text,
  signed_at timestamptz DEFAULT now()
);

ALTER TABLE public.beauty_packages           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beauty_gallery            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beauty_consent_forms      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.beauty_consent_signatures ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bpkg_owner ON public.beauty_packages;
CREATE POLICY bpkg_owner ON public.beauty_packages
  FOR ALL USING (public.check_service_owner(professional_service_id)) WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS bpkg_public_read ON public.beauty_packages;
CREATE POLICY bpkg_public_read ON public.beauty_packages FOR SELECT USING (is_active = true);

DROP POLICY IF EXISTS bgal_owner ON public.beauty_gallery;
CREATE POLICY bgal_owner ON public.beauty_gallery
  FOR ALL USING (public.check_service_owner(professional_service_id)) WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS bgal_public_read ON public.beauty_gallery;
CREATE POLICY bgal_public_read ON public.beauty_gallery FOR SELECT USING (is_public = true);
DROP POLICY IF EXISTS bgal_client_read ON public.beauty_gallery;
CREATE POLICY bgal_client_read ON public.beauty_gallery FOR SELECT TO authenticated USING (client_user_id = auth.uid());

DROP POLICY IF EXISTS bcf_owner ON public.beauty_consent_forms;
CREATE POLICY bcf_owner ON public.beauty_consent_forms
  FOR ALL USING (public.check_service_owner(professional_service_id)) WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS bcf_public_read ON public.beauty_consent_forms;
CREATE POLICY bcf_public_read ON public.beauty_consent_forms FOR SELECT USING (is_active = true);

DROP POLICY IF EXISTS bcs_owner ON public.beauty_consent_signatures;
CREATE POLICY bcs_owner ON public.beauty_consent_signatures FOR SELECT TO authenticated USING (
  client_user_id = auth.uid()
  OR public.check_service_owner((SELECT professional_service_id FROM public.beauty_consent_forms WHERE id = form_id))
);
DROP POLICY IF EXISTS bcs_client_sign ON public.beauty_consent_signatures;
CREATE POLICY bcs_client_sign ON public.beauty_consent_signatures FOR INSERT TO authenticated WITH CHECK (client_user_id = auth.uid());

SELECT 'Beauté Phase 2 : forfaits + galerie avant/après + formulaires de consentement.' AS status;
