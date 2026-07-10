-- ============================================================================
-- 🏥 CLINIQUE — Phase 3 : ORDONNANCE NUMÉRIQUE + PONT PHARMACIE 224
-- ----------------------------------------------------------------------------
-- clinic_prescriptions = l'ordonnance émise par la clinique (lignes prescrites).
-- Le PONT (route backend send-to-pharmacy) génère un PDF (bucket privé prescriptions,
-- dossier clinic/) et INJECTE une ligne dans la table `prescriptions` EXISTANTE de la
-- pharmacie choisie (status='pending') → elle entre dans le flux pharmacie NORMAL
-- (validation pharmacien → devis → paiement) SANS le modifier. Le pharmacien re-saisit
-- et chiffre lui-même les médicaments (obligation légale) — les lignes clinique sont
-- INFORMATIVES (contenu du PDF).
--
-- 🔒 Immuable après émission (comme la consultation). RLS : praticien de la clinique +
--    patient lié en lecture. Aucune policy `true` (sauf service_role).
-- ⚠️ L'envoi in-app exige clinic_patients.user_id NON NULL (client_id obligatoire côté
--    pharmacie) ; sinon chemin papier (PDF imprimé remis au patient).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.clinic_prescriptions (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  consultation_id         uuid REFERENCES public.clinic_consultations(id) ON DELETE SET NULL,
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  patient_id              uuid NOT NULL REFERENCES public.clinic_patients(id) ON DELETE CASCADE,
  lines                   jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{medication,dosage,duration,instructions}]
  status                  text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued','sent_to_pharmacy','dispensed','cancelled')),
  pdf_path                text,                                 -- bucket PRIVÉ prescriptions, dossier clinic/
  sent_prescription_id    uuid,                                 -- FK vers prescriptions pharmacie une fois envoyée
  created_by              uuid NOT NULL DEFAULT auth.uid(),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_clinic_prescriptions_patient      ON public.clinic_prescriptions (patient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_clinic_prescriptions_service      ON public.clinic_prescriptions (professional_service_id);
CREATE INDEX IF NOT EXISTS idx_clinic_prescriptions_consultation ON public.clinic_prescriptions (consultation_id) WHERE consultation_id IS NOT NULL;

ALTER TABLE public.clinic_prescriptions ENABLE ROW LEVEL SECURITY;

-- Lecture : praticien propriétaire (tout) OU patient lié.
DROP POLICY IF EXISTS clinic_prescriptions_read ON public.clinic_prescriptions;
CREATE POLICY clinic_prescriptions_read ON public.clinic_prescriptions
  FOR SELECT TO authenticated
  USING (
    public.check_service_owner(professional_service_id)
    OR EXISTS (SELECT 1 FROM public.clinic_patients cp
               WHERE cp.id = clinic_prescriptions.patient_id AND cp.user_id = auth.uid())
  );

-- Émission : praticien propriétaire.
DROP POLICY IF EXISTS clinic_prescriptions_insert ON public.clinic_prescriptions;
CREATE POLICY clinic_prescriptions_insert ON public.clinic_prescriptions
  FOR INSERT TO authenticated
  WITH CHECK (public.check_service_owner(professional_service_id));

-- 🔒 Immuabilité : le praticien ne peut que l'ANNULER tant qu'elle est 'issued' (jamais
--    réécrire les lignes). L'envoi (status='sent_to_pharmacy' + sent_prescription_id + pdf_path)
--    est fait par le backend service_role (route send-to-pharmacy), qui bypasse cette RLS.
DROP POLICY IF EXISTS clinic_prescriptions_update_issued ON public.clinic_prescriptions;
CREATE POLICY clinic_prescriptions_update_issued ON public.clinic_prescriptions
  FOR UPDATE TO authenticated
  USING (public.check_service_owner(professional_service_id) AND status = 'issued')
  WITH CHECK (public.check_service_owner(professional_service_id) AND status IN ('issued','cancelled'));

DROP POLICY IF EXISTS clinic_prescriptions_service_role ON public.clinic_prescriptions;
CREATE POLICY clinic_prescriptions_service_role ON public.clinic_prescriptions
  FOR ALL TO service_role USING (true) WITH CHECK (true);

DROP TRIGGER IF EXISTS trg_touch_clinic_prescriptions ON public.clinic_prescriptions;
CREATE TRIGGER trg_touch_clinic_prescriptions BEFORE UPDATE ON public.clinic_prescriptions
  FOR EACH ROW EXECUTE FUNCTION public.touch_clinic_patients_updated_at();

SELECT 'Clinique Phase 3 : clinic_prescriptions (RLS praticien+patient, immuable) — le pont pharmacie se fait cote backend (route send-to-pharmacy, injection dans prescriptions).' AS status;
