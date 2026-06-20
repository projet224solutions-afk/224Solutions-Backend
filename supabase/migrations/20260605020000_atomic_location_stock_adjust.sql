-- =====================================================================
-- AJUSTEMENT DE STOCK ENTREPÔT ATOMIQUE (location_stock)
-- =====================================================================
-- BUG : useMultiWarehouse.adjustStock (frontend) lisait location_stock.quantity
-- puis faisait un upsert avec la nouvelle valeur → read-then-write non atomique
-- (course → quantity_before faux dans l'historique, ajustement concurrent perdu),
-- et sans contrôle d'appartenance côté serveur.
--
-- CORRECTIF : RPC qui verrouille la ligne (FOR UPDATE), écrit quantité + historique
-- dans la MÊME transaction, et vérifie que le lieu appartient bien au vendeur de
-- l'utilisateur courant (auth.uid()). Le backend (service_role, auth.uid() NULL)
-- reste autorisé.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.adjust_location_stock_atomic(
  p_location_id uuid,
  p_product_id uuid,
  p_new_quantity int,
  p_reason text,
  p_user_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_prev int;
  v_change int;
BEGIN
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Quantité invalide (doit être ≥ 0)');
  END IF;

  -- Contrôle d'appartenance (sauf appel backend service_role où auth.uid() est NULL)
  IF auth.uid() IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.vendor_locations vl
    JOIN public.vendors v ON v.id = vl.vendor_id
    WHERE vl.id = p_location_id AND v.user_id = auth.uid()
  ) THEN
    RETURN jsonb_build_object('status', 'error', 'error', 'Lieu non autorisé');
  END IF;

  -- Verrou de ligne : sérialise les ajustements concurrents
  SELECT quantity INTO v_prev
  FROM public.location_stock
  WHERE location_id = p_location_id AND product_id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    v_prev := 0;
    INSERT INTO public.location_stock (location_id, product_id, quantity, last_stock_update)
    VALUES (p_location_id, p_product_id, p_new_quantity, now())
    ON CONFLICT (location_id, product_id)
      DO UPDATE SET quantity = EXCLUDED.quantity, last_stock_update = now();
  ELSE
    v_prev := COALESCE(v_prev, 0);
    UPDATE public.location_stock
    SET quantity = p_new_quantity, last_stock_update = now()
    WHERE location_id = p_location_id AND product_id = p_product_id;
  END IF;

  v_change := p_new_quantity - v_prev;

  INSERT INTO public.location_stock_history (
    location_id, product_id, movement_type,
    quantity_before, quantity_change, quantity_after, performed_by, notes
  ) VALUES (
    p_location_id, p_product_id, 'adjustment',
    v_prev, v_change, p_new_quantity, p_user_id, p_reason
  );

  RETURN jsonb_build_object('status', 'success', 'previous', v_prev, 'new', p_new_quantity, 'change', v_change);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('status', 'error', 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.adjust_location_stock_atomic(uuid, uuid, int, text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_location_stock_atomic(uuid, uuid, int, text, uuid) TO service_role;
