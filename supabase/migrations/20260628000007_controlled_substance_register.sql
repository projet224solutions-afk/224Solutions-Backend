-- ============================================================================
-- PHARMACIE — CONFORMITÉ 1.2 : registre des médicaments contrôlés (APPEND-ONLY)
-- Aucune policy UPDATE/DELETE → registre inviolable. Écriture via RPC
-- register_controlled_dispensation (PROPRIÉTAIRE uniquement). Lecture : propriétaire
-- + admin/pdg/ceo (contrôle réglementaire).
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.controlled_substance_register (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id       UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  dispensed_by      UUID NOT NULL,
  medication_id     UUID REFERENCES public.pharmacy_medications(id) ON DELETE SET NULL,
  medication_name   TEXT NOT NULL,
  control_level     TEXT NOT NULL,
  quantity          INTEGER NOT NULL,
  batch_number      TEXT,
  patient_name      TEXT,
  patient_id_ref    TEXT,
  prescription_id   UUID REFERENCES public.prescriptions(id) ON DELETE SET NULL,
  prescription_ref  TEXT,
  prescriber_name   TEXT,
  order_id          UUID,
  dispensed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_csr_pharmacy_date
  ON public.controlled_substance_register (pharmacy_id, dispensed_at DESC);
CREATE INDEX IF NOT EXISTS idx_csr_medication
  ON public.controlled_substance_register (medication_id);

ALTER TABLE public.controlled_substance_register ENABLE ROW LEVEL SECURITY;

-- Lecture : pharmacien PROPRIÉTAIRE + admin/pdg/ceo
DROP POLICY IF EXISTS "csr_read" ON public.controlled_substance_register;
CREATE POLICY "csr_read" ON public.controlled_substance_register
  FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.professional_services ps
            WHERE ps.id = pharmacy_id AND ps.user_id = auth.uid())
    OR EXISTS (SELECT 1 FROM public.profiles
               WHERE id = auth.uid() AND role IN ('admin','pdg','ceo'))
  );
-- ⚠️ APPEND-ONLY : aucune policy UPDATE ni DELETE. Registre inviolable.

CREATE OR REPLACE FUNCTION public.register_controlled_dispensation(
  p_pharmacy_id     uuid,
  p_medication_id   uuid,
  p_quantity        integer,
  p_patient_name    text DEFAULT NULL,
  p_patient_id_ref  text DEFAULT NULL,
  p_prescription_id uuid DEFAULT NULL,
  p_prescription_ref text DEFAULT NULL,
  p_prescriber_name text DEFAULT NULL,
  p_order_id        uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_owner uuid;
  v_uid   uuid := auth.uid();
  v_med   record;
  v_id    uuid;
BEGIN
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_pharmacy_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'PHARMACIE_INTROUVABLE');
  END IF;
  -- ✅ PROPRIÉTAIRE uniquement (aucune table d'agents)
  IF v_uid IS NULL OR v_uid <> v_owner THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;

  SELECT id, name, control_level, batch_number INTO v_med
  FROM public.pharmacy_medications
  WHERE id = p_medication_id AND pharmacy_id = p_pharmacy_id;

  IF v_med IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'MEDICAMENT_INTROUVABLE');
  END IF;
  IF v_med.control_level NOT IN ('controlled','narcotic') THEN
    RETURN jsonb_build_object('success', false, 'error', 'MEDICAMENT_NON_CONTROLE');
  END IF;

  INSERT INTO public.controlled_substance_register (
    pharmacy_id, dispensed_by, medication_id, medication_name, control_level,
    quantity, batch_number, patient_name, patient_id_ref,
    prescription_id, prescription_ref, prescriber_name, order_id
  ) VALUES (
    p_pharmacy_id, v_uid, p_medication_id, v_med.name, v_med.control_level,
    GREATEST(1, p_quantity), v_med.batch_number, p_patient_name, p_patient_id_ref,
    p_prescription_id, p_prescription_ref, p_prescriber_name, p_order_id
  )
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('success', true, 'register_id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION public.register_controlled_dispensation FROM anon;
GRANT  EXECUTE ON FUNCTION public.register_controlled_dispensation TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_tables WHERE tablename='controlled_substance_register')
  THEN RAISE EXCEPTION 'registre contrôlés absent'; END IF;
  RAISE NOTICE '✅ Migration controlled_substance_register OK';
END; $$;

COMMIT;
