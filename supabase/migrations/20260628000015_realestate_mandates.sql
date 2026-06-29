-- ============================================================================
-- IMMOBILIER — OUTIL 2 : mandats (base juridique agent ↔ vendeur/bailleur).
-- Confidentialité : check_service_owner. Additif.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.property_mandates (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  property_id   UUID REFERENCES public.properties(id) ON DELETE SET NULL,
  mandant_name  TEXT NOT NULL,
  mandant_phone TEXT,
  mandant_email TEXT,
  mandate_type  TEXT NOT NULL DEFAULT 'simple' CHECK (mandate_type IN ('simple','exclusif','semi_exclusif')),
  commission_rate NUMERIC,
  start_date    DATE NOT NULL DEFAULT CURRENT_DATE,
  end_date      DATE,
  status        TEXT NOT NULL DEFAULT 'actif' CHECK (status IN ('actif','expire','resilie','conclu')),
  reference     TEXT,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mandates_service
  ON public.property_mandates (professional_service_id, status);

ALTER TABLE public.property_mandates ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mandates_owner ON public.property_mandates;
CREATE POLICY mandates_owner ON public.property_mandates
  FOR ALL TO authenticated
  USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));

-- RPC : mandats qui expirent bientôt (alerte agent)
CREATE OR REPLACE FUNCTION public.mandates_expiring_soon(p_service_id uuid, p_days integer DEFAULT 15)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_rows jsonb;
BEGIN
  IF NOT public.check_service_owner(p_service_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'mandant_name', mandant_name, 'property_id', property_id,
    'end_date', end_date, 'days_left', (end_date - CURRENT_DATE)
  ) ORDER BY end_date), '[]'::jsonb)
  INTO v_rows
  FROM public.property_mandates
  WHERE professional_service_id = p_service_id AND status = 'actif'
    AND end_date IS NOT NULL
    AND end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + (p_days || ' days')::interval;
  RETURN jsonb_build_object('success', true, 'mandates', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.mandates_expiring_soon(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.mandates_expiring_soon(uuid, integer) TO authenticated, service_role;

COMMIT;
