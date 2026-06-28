-- ============================================================================
-- PHARMACIE — CONFORMITÉ 1.1 : colonnes contrôle/péremption + lots (FEFO) + alertes
-- Autorisation = PROPRIÉTAIRE (professional_services.user_id), pas de table d'agents (inexistante).
-- Classifications/seuils = paramètres ADAPTABLES (à valider par pharmacien/juriste).
-- ============================================================================

BEGIN;

ALTER TABLE public.pharmacy_medications
  -- Niveau de contrôle (ADAPTABLE) : 'none' libre · 'prescription' ordonnance simple
  --   'controlled' liste contrôlée (registre) · 'narcotic' stupéfiant (registre strict)
  ADD COLUMN IF NOT EXISTS control_level TEXT NOT NULL DEFAULT 'none'
    CHECK (control_level IN ('none','prescription','controlled','narcotic')),
  ADD COLUMN IF NOT EXISTS expiry_date DATE,
  ADD COLUMN IF NOT EXISTS batch_number TEXT;

CREATE INDEX IF NOT EXISTS idx_pharmacy_med_expiry
  ON public.pharmacy_medications (pharmacy_id, expiry_date)
  WHERE expiry_date IS NOT NULL AND is_active = true;

CREATE INDEX IF NOT EXISTS idx_pharmacy_med_control
  ON public.pharmacy_medications (pharmacy_id, control_level)
  WHERE control_level IN ('controlled','narcotic');

-- (Optionnel) Lots multiples avec péremptions distinctes (FEFO)
CREATE TABLE IF NOT EXISTS public.pharmacy_medication_batches (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  medication_id UUID NOT NULL REFERENCES public.pharmacy_medications(id) ON DELETE CASCADE,
  pharmacy_id   UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  batch_number  TEXT,
  quantity      INTEGER NOT NULL DEFAULT 0,
  expiry_date   DATE NOT NULL,
  received_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_med_batches_expiry
  ON public.pharmacy_medication_batches (pharmacy_id, expiry_date, quantity);

ALTER TABLE public.pharmacy_medication_batches ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "pharmacy_batches_owner" ON public.pharmacy_medication_batches;
CREATE POLICY "pharmacy_batches_owner" ON public.pharmacy_medication_batches
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.professional_services ps
                 WHERE ps.id = pharmacy_id AND ps.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.professional_services ps
                 WHERE ps.id = pharmacy_id AND ps.user_id = auth.uid()));

-- RPC alertes péremption (PROPRIÉTAIRE uniquement)
CREATE OR REPLACE FUNCTION public.pharmacy_expiry_alerts(
  p_pharmacy_id uuid,
  p_days_ahead  integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_owner uuid;
  v_expired jsonb;
  v_soon    jsonb;
BEGIN
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_pharmacy_id;
  IF v_owner IS NULL OR auth.uid() <> v_owner THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id', id, 'name', name, 'expiry_date', expiry_date, 'stock', stock)), '[]'::jsonb)
  INTO v_expired
  FROM public.pharmacy_medications
  WHERE pharmacy_id = p_pharmacy_id AND is_active = true
    AND expiry_date IS NOT NULL AND expiry_date < CURRENT_DATE;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id', id, 'name', name, 'expiry_date', expiry_date, 'stock', stock,
            'days_left', (expiry_date - CURRENT_DATE))), '[]'::jsonb)
  INTO v_soon
  FROM public.pharmacy_medications
  WHERE pharmacy_id = p_pharmacy_id AND is_active = true
    AND expiry_date IS NOT NULL
    AND expiry_date >= CURRENT_DATE
    AND expiry_date <= CURRENT_DATE + (p_days_ahead || ' days')::interval;

  RETURN jsonb_build_object('success', true, 'expired', v_expired, 'expiring_soon', v_soon);
END;
$$;

REVOKE ALL ON FUNCTION public.pharmacy_expiry_alerts(uuid, integer) FROM anon;
GRANT  EXECUTE ON FUNCTION public.pharmacy_expiry_alerts(uuid, integer) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns
                WHERE table_name='pharmacy_medications' AND column_name='control_level')
  THEN RAISE EXCEPTION 'colonne control_level absente'; END IF;
  RAISE NOTICE '✅ Migration pharmacy_compliance_fields OK';
END; $$;

COMMIT;
