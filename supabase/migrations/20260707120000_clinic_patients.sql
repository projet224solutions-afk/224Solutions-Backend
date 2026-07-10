-- ============================================================================
-- 🏥 CLINIQUE — Phase 1 : DOSSIER PATIENT (table clinic_patients + RLS stricte)
-- ----------------------------------------------------------------------------
-- Le ClinicModule dérivait son « fichier patients » d'un useMemo recalculé depuis
-- proximity_bookings (aucune persistance, aucun id stable, aucune allergie/antécédent).
-- On matérialise un VRAI dossier patient par clinique.
--
-- 🔒 DONNÉES DE SANTÉ — RLS ULTRA-STRICTE (modèle prescriptions/pharmacie) :
--   • le PRATICIEN propriétaire de CETTE clinique (check_service_owner) gère ses patients ;
--   • le PATIENT lié (user_id = auth.uid()) LIT son propre dossier (lecture seule) ;
--   • AUCUNE autre lecture. Aucune policy `true` (sauf service_role backend).
-- Le lien compte app (user_id) est OPTIONNEL (walk-in sans compte = chemin papier).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.clinic_patients (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  user_id                 uuid REFERENCES auth.users(id) ON DELETE SET NULL,  -- compte app lié (optionnel)
  full_name               text NOT NULL,
  phone                   text,
  birth_date              date,
  sex                     text CHECK (sex IS NULL OR sex IN ('M','F','autre')),
  blood_group             text,
  allergies               text,
  chronic_conditions      text,
  notes                   text,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  -- Dédup par téléphone au sein d'une clinique (les NULL ne conflictent pas = walk-ins sans tel).
  UNIQUE (professional_service_id, phone)
);

CREATE INDEX IF NOT EXISTS idx_clinic_patients_service ON public.clinic_patients (professional_service_id);
CREATE INDEX IF NOT EXISTS idx_clinic_patients_user    ON public.clinic_patients (user_id) WHERE user_id IS NOT NULL;

ALTER TABLE public.clinic_patients ENABLE ROW LEVEL SECURITY;

-- Praticien propriétaire de la clinique : gestion complète de SES patients.
DROP POLICY IF EXISTS clinic_patients_owner ON public.clinic_patients;
CREATE POLICY clinic_patients_owner ON public.clinic_patients
  FOR ALL TO authenticated
  USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));

-- Patient lié : lecture SEULE de son propre dossier.
DROP POLICY IF EXISTS clinic_patients_self_read ON public.clinic_patients;
CREATE POLICY clinic_patients_self_read ON public.clinic_patients
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- Backend (service_role) : plein accès (endpoints internes).
DROP POLICY IF EXISTS clinic_patients_service_role ON public.clinic_patients;
CREATE POLICY clinic_patients_service_role ON public.clinic_patients
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- updated_at auto.
CREATE OR REPLACE FUNCTION public.touch_clinic_patients_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS trg_touch_clinic_patients ON public.clinic_patients;
CREATE TRIGGER trg_touch_clinic_patients BEFORE UPDATE ON public.clinic_patients
  FOR EACH ROW EXECUTE FUNCTION public.touch_clinic_patients_updated_at();

-- ── Migration douce : importer les patients dérivés des RDV existants (idempotent) ──
-- Réservée au praticien propriétaire ; dédup par téléphone (le plus récent RDV fait foi
-- pour le nom + le lien compte client_id). Les RDV sans téléphone sont ignorés (non déduplicables).
CREATE OR REPLACE FUNCTION public.import_clinic_patients_from_bookings(p_service_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_count integer;
BEGIN
  IF NOT public.check_service_owner(p_service_id) THEN RAISE EXCEPTION 'NOT_OWNER'; END IF;

  INSERT INTO public.clinic_patients (professional_service_id, user_id, full_name, phone)
  SELECT DISTINCT ON (b.customer_phone)
         p_service_id,
         b.client_id,
         COALESCE(NULLIF(btrim(b.customer_name), ''), 'Patient'),
         btrim(b.customer_phone)
  FROM public.proximity_bookings b
  WHERE b.service_id = p_service_id
    AND b.customer_phone IS NOT NULL
    AND btrim(b.customer_phone) <> ''
  ORDER BY b.customer_phone, b.created_at DESC
  ON CONFLICT (professional_service_id, phone) DO NOTHING;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'imported', v_count);
END;
$$;

REVOKE ALL ON FUNCTION public.import_clinic_patients_from_bookings(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.import_clinic_patients_from_bookings(uuid) TO authenticated;

SELECT 'Clinique Phase 1 : clinic_patients (RLS praticien+patient stricte) + migration douce import_clinic_patients_from_bookings.' AS status;
