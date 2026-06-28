-- ============================================================================
-- PHARMACIE — AMÉLIORATION 2.2 : équivalents génériques EN STOCK (même pharmacie).
-- Lit le tableau EXISTANT pharmacy_medications.generic_equivalents (TEXT[]).
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.generic_alternatives(p_medication_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE v_pharmacy uuid; v_equivalents text[]; v_rows jsonb;
BEGIN
  SELECT pharmacy_id, generic_equivalents INTO v_pharmacy, v_equivalents
  FROM public.pharmacy_medications WHERE id = p_medication_id;
  IF v_pharmacy IS NULL OR v_equivalents IS NULL OR array_length(v_equivalents, 1) IS NULL THEN
    RETURN jsonb_build_object('success', true, 'alternatives', '[]'::jsonb);
  END IF;
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'name', name, 'price', price, 'stock', stock,
    'requires_prescription', requires_prescription
  ) ORDER BY price ASC), '[]'::jsonb)
  INTO v_rows
  FROM public.pharmacy_medications
  WHERE pharmacy_id = v_pharmacy AND is_active = true AND stock > 0
    AND name = ANY(v_equivalents);
  RETURN jsonb_build_object('success', true, 'alternatives', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.generic_alternatives(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.generic_alternatives(uuid) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='generic_alternatives')
  THEN RAISE EXCEPTION 'RPC generic_alternatives absente'; END IF;
  RAISE NOTICE '✅ Migration generic_alternatives OK';
END; $$;

COMMIT;
