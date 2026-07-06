-- ============================================================================
-- 🏥 CLINIQUE — Phase 2 : CONSULTATIONS STRUCTURÉES (clinic_consultations)
-- ----------------------------------------------------------------------------
-- Une consultation = motif, constantes (vitals), examen, diagnostic, liée à un patient
-- (clinic_patients) et OPTIONNELLEMENT à un RDV (proximity_bookings.id).
--
-- 🔒 VERROU D'INTÉGRITÉ MÉDICALE (pattern journal BTP) : une consultation 'finalized'
--   devient IMMUABLE — la policy UPDATE n'autorise que les 'draft'. Un compte-rendu
--   médical ne se réécrit pas après coup. La finalisation (draft→finalized) est le
--   DERNIER UPDATE possible.
-- 🔒 RLS : le PRATICIEN de CETTE clinique (check_service_owner) gère ; le PATIENT lié
--   LIT ses consultations FINALISÉES (jamais les brouillons). Aucune policy `true`.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.clinic_consultations (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  patient_id              uuid NOT NULL REFERENCES public.clinic_patients(id) ON DELETE CASCADE,
  booking_id              uuid,  -- lien RDV optionnel (proximity_bookings.id) ; pas de FK dure
  motif                   text,
  examination             text,
  diagnosis               text,
  vitals                  jsonb,  -- { tension, temperature, poids, ... }
  status                  text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','finalized')),
  finalized_at            timestamptz,
  created_by              uuid NOT NULL DEFAULT auth.uid(),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_clinic_consultations_patient ON public.clinic_consultations (patient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_clinic_consultations_service ON public.clinic_consultations (professional_service_id);
CREATE INDEX IF NOT EXISTS idx_clinic_consultations_booking ON public.clinic_consultations (booking_id) WHERE booking_id IS NOT NULL;

ALTER TABLE public.clinic_consultations ENABLE ROW LEVEL SECURITY;

-- Lecture : praticien propriétaire (tout) OU patient lié (FINALISÉES uniquement).
DROP POLICY IF EXISTS clinic_consultations_read ON public.clinic_consultations;
CREATE POLICY clinic_consultations_read ON public.clinic_consultations
  FOR SELECT TO authenticated
  USING (
    public.check_service_owner(professional_service_id)
    OR (
      status = 'finalized'
      AND EXISTS (SELECT 1 FROM public.clinic_patients cp
                  WHERE cp.id = clinic_consultations.patient_id AND cp.user_id = auth.uid())
    )
  );

-- Création : praticien propriétaire.
DROP POLICY IF EXISTS clinic_consultations_insert ON public.clinic_consultations;
CREATE POLICY clinic_consultations_insert ON public.clinic_consultations
  FOR INSERT TO authenticated
  WITH CHECK (public.check_service_owner(professional_service_id));

-- 🔒 Modification : praticien propriétaire ET UNIQUEMENT si status='draft' (immuabilité).
--    Une fois 'finalized', l'USING échoue → plus aucun UPDATE possible.
DROP POLICY IF EXISTS clinic_consultations_update_draft ON public.clinic_consultations;
CREATE POLICY clinic_consultations_update_draft ON public.clinic_consultations
  FOR UPDATE TO authenticated
  USING (public.check_service_owner(professional_service_id) AND status = 'draft')
  WITH CHECK (public.check_service_owner(professional_service_id));

-- Suppression : praticien propriétaire ET seulement un brouillon.
DROP POLICY IF EXISTS clinic_consultations_delete_draft ON public.clinic_consultations;
CREATE POLICY clinic_consultations_delete_draft ON public.clinic_consultations
  FOR DELETE TO authenticated
  USING (public.check_service_owner(professional_service_id) AND status = 'draft');

DROP POLICY IF EXISTS clinic_consultations_service_role ON public.clinic_consultations;
CREATE POLICY clinic_consultations_service_role ON public.clinic_consultations
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- updated_at auto (uniquement pertinent sur les brouillons, seuls modifiables).
DROP TRIGGER IF EXISTS trg_touch_clinic_consultations ON public.clinic_consultations;
CREATE TRIGGER trg_touch_clinic_consultations BEFORE UPDATE ON public.clinic_consultations
  FOR EACH ROW EXECUTE FUNCTION public.touch_clinic_patients_updated_at();

SELECT 'Clinique Phase 2 : clinic_consultations (RLS praticien+patient) + verrou immuabilite (UPDATE draft-only).' AS status;
