-- ============================================================================
-- IMMOBILIER — OUTIL 4 : état des lieux (entrée/sortie avec photos). Justifie
-- objectivement la décision de caution (release_deposit_atomic, NON modifiée).
-- RLS : propriétaire du service (FOR ALL) + locataire du bail (lecture).
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.lease_inventories (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lease_id      UUID NOT NULL REFERENCES public.rental_leases(id) ON DELETE CASCADE,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  kind          TEXT NOT NULL CHECK (kind IN ('entree','sortie')),
  -- [{ "room":"Salon", "condition":"bon", "notes":"...", "photos":["path1"] }]
  rooms         JSONB NOT NULL DEFAULT '[]'::jsonb,
  general_notes TEXT,
  done_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_inventories_lease ON public.lease_inventories (lease_id, kind);

ALTER TABLE public.lease_inventories ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS inventories_owner ON public.lease_inventories;
CREATE POLICY inventories_owner ON public.lease_inventories
  FOR ALL TO authenticated
  USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS inventories_tenant_read ON public.lease_inventories;
CREATE POLICY inventories_tenant_read ON public.lease_inventories
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.rental_leases l
                 WHERE l.id = lease_id AND l.tenant_user_id = auth.uid()));

COMMIT;
