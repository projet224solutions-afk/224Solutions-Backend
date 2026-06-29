-- ============================================================================
-- IMMOBILIER — OUTIL 1 : pipeline commercial (CRM). Enrichit property_contacts
-- (liste plate) en pipeline d'affaires + historique d'interactions. Additif.
-- Confidentialité : check_service_owner (chaque agent ne voit que ses données).
-- ============================================================================

BEGIN;

ALTER TABLE public.property_contacts
  ADD COLUMN IF NOT EXISTS pipeline_stage TEXT NOT NULL DEFAULT 'nouveau'
    CHECK (pipeline_stage IN ('nouveau','contacte','visite_planifiee','visite_faite',
                              'offre','negociation','conclu','perdu')),
  ADD COLUMN IF NOT EXISTS property_id UUID REFERENCES public.properties(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS budget_min NUMERIC,
  ADD COLUMN IF NOT EXISTS budget_max NUMERIC,
  ADD COLUMN IF NOT EXISTS next_followup_date DATE,
  ADD COLUMN IF NOT EXISTS last_contact_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS lost_reason TEXT;

CREATE INDEX IF NOT EXISTS idx_contacts_pipeline
  ON public.property_contacts (professional_service_id, pipeline_stage);
CREATE INDEX IF NOT EXISTS idx_contacts_followup
  ON public.property_contacts (professional_service_id, next_followup_date)
  WHERE next_followup_date IS NOT NULL;

-- Historique d'interactions (appels, messages, notes, visites, emails)
CREATE TABLE IF NOT EXISTS public.contact_interactions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id  UUID NOT NULL REFERENCES public.property_contacts(id) ON DELETE CASCADE,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  type        TEXT NOT NULL DEFAULT 'note' CHECK (type IN ('note','appel','message','visite','email')),
  content     TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_interactions_contact
  ON public.contact_interactions (contact_id, created_at DESC);

ALTER TABLE public.contact_interactions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS interactions_owner ON public.contact_interactions;
CREATE POLICY interactions_owner ON public.contact_interactions
  FOR ALL TO authenticated
  USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));

-- RPC : prospects à relancer (next_followup_date <= aujourd'hui), hors conclu/perdu
CREATE OR REPLACE FUNCTION public.my_followups_due(p_service_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_rows jsonb;
BEGIN
  IF NOT public.check_service_owner(p_service_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'name', name, 'phone', phone, 'pipeline_stage', pipeline_stage,
    'next_followup_date', next_followup_date, 'property_id', property_id
  ) ORDER BY next_followup_date), '[]'::jsonb)
  INTO v_rows
  FROM public.property_contacts
  WHERE professional_service_id = p_service_id
    AND pipeline_stage NOT IN ('conclu','perdu')
    AND next_followup_date IS NOT NULL
    AND next_followup_date <= CURRENT_DATE;
  RETURN jsonb_build_object('success', true, 'followups', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.my_followups_due(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.my_followups_due(uuid) TO authenticated, service_role;

COMMIT;
