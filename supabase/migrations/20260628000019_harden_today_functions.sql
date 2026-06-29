-- ============================================================================
-- DURCISSEMENT des RPC ajoutées aujourd'hui (2026-06-28).
--
-- 🔴 FAILLE : ces fonctions SECURITY DEFINER faisaient seulement
--    REVOKE ... FROM anon → le GRANT EXECUTE par défaut à PUBLIC RESTAIT, donc
--    n'importe quel rôle (y compris anon via PostgREST) pouvait les exécuter.
--    Cas graves : treatments_to_notify() (renvoie les traitements de TOUS les
--    clients, aucune garde) ; find_medication_nearby / generic_alternatives
--    (énumération du catalogue). Règle plateforme : REVOKE EXECUTE FROM PUBLIC
--    sur tout SECURITY DEFINER sensible.
--
-- + Idempotence du registre des contrôlés (append-only inviolable) : empêche la
--   double inscription d'une même délivrance (double-clic / rejeu de vente).
-- Idempotent et rejouable.
-- ============================================================================

BEGIN;

-- ── 1. Idempotence register_controlled_dispensation (garde anti double-inscription) ──
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

  -- ✅ Idempotence : si déjà consigné pour cette commande + ce médicament, ne pas dupliquer
  IF p_order_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.controlled_substance_register
    WHERE order_id = p_order_id AND medication_id = p_medication_id
  ) THEN
    RETURN jsonb_build_object('success', true, 'already_registered', true);
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

-- ── 2. REVOKE EXECUTE FROM PUBLIC (+ anon) sur toutes les RPC d'aujourd'hui ──
--    puis re-GRANT au strict nécessaire. Defense-in-depth en plus des gardes internes.

-- Restaurant
REVOKE ALL ON FUNCTION public.finalize_restaurant_card_order(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.finalize_restaurant_card_order(uuid) TO authenticated, service_role;

-- Pharmacie
REVOKE ALL ON FUNCTION public.pharmacy_expiry_alerts(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.pharmacy_expiry_alerts(uuid, integer) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.register_controlled_dispensation(uuid, uuid, integer, text, text, uuid, text, text, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.register_controlled_dispensation(uuid, uuid, integer, text, text, uuid, text, text, uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.my_treatments_ending_soon(integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.my_treatments_ending_soon(integer) TO authenticated;

-- ⚠️ Fonction worker : renvoie des données de TOUS les clients → service_role UNIQUEMENT
REVOKE ALL ON FUNCTION public.treatments_to_notify() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.treatments_to_notify() TO service_role;

REVOKE ALL ON FUNCTION public.generic_alternatives(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.generic_alternatives(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.find_medication_nearby(text, double precision, double precision, double precision) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.find_medication_nearby(text, double precision, double precision, double precision) TO authenticated, service_role;

-- Immobilier
REVOKE ALL ON FUNCTION public.my_followups_due(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.my_followups_due(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.mandates_expiring_soon(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mandates_expiring_soon(uuid, integer) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.match_prospects_for_property(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.match_prospects_for_property(uuid) TO authenticated, service_role;

DO $$
BEGIN
  RAISE NOTICE '✅ Durcissement : REVOKE FROM PUBLIC sur 10 RPC + idempotence registre contrôlés';
END; $$;

COMMIT;
