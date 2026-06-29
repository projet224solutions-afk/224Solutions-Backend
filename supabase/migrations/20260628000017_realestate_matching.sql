-- ============================================================================
-- IMMOBILIER — OUTIL 5 : rapprochement biens ↔ prospects (matching). À l'ajout
-- d'un bien, trouver les prospects du CRM dont le budget + type correspondent.
-- Réservé au propriétaire du service. offer_type='vente'→contact_type='acheteur',
-- offer_type='location'→contact_type='locataire'.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.match_prospects_for_property(p_property_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_prop record;
  v_rows jsonb;
BEGIN
  SELECT id, professional_service_id, offer_type, price, property_type
  INTO v_prop FROM public.properties WHERE id = p_property_id;
  IF v_prop IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'BIEN_INTROUVABLE');
  END IF;
  IF NOT public.check_service_owner(v_prop.professional_service_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'name', name, 'phone', phone, 'pipeline_stage', pipeline_stage,
    'budget_min', budget_min, 'budget_max', budget_max
  )), '[]'::jsonb)
  INTO v_rows
  FROM public.property_contacts
  WHERE professional_service_id = v_prop.professional_service_id
    AND pipeline_stage NOT IN ('conclu','perdu')
    AND ( (v_prop.offer_type = 'vente'    AND contact_type = 'acheteur')
       OR (v_prop.offer_type = 'location' AND contact_type = 'locataire') )
    AND (budget_max IS NULL OR budget_max >= v_prop.price)
    AND (budget_min IS NULL OR budget_min <= v_prop.price);

  RETURN jsonb_build_object('success', true, 'prospects', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.match_prospects_for_property(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.match_prospects_for_property(uuid) TO authenticated, service_role;

COMMIT;
