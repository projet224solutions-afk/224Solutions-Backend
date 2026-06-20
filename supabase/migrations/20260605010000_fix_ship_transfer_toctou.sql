-- =====================================================================
-- FIX TOCTOU dans ship_transfer (expédition de transfert entrepôt)
-- =====================================================================
-- BUG : ship_transfer vérifiait la disponibilité via un SELECT, PUIS décrémentait
-- via un UPDATE séparé. Entre les deux, une expédition concurrente du même produit
-- pouvait passer le même test → double décrément → stock entrepôt NÉGATIF.
--
-- CORRECTIF : décrément GARDÉ atomique en UNE instruction
--   UPDATE … SET quantity = quantity - sent
--   WHERE … AND COALESCE(available_quantity, quantity, 0) >= sent
-- Si aucune ligne n'est affectée (stock insuffisant ou ligne absente) → erreur.
-- Le verrou de ligne implicite de l'UPDATE sérialise les expéditions concurrentes.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.ship_transfer(
  p_transfer_id   UUID,
  p_shipped_by    UUID    DEFAULT NULL,
  p_shipping_notes TEXT   DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer  RECORD;
  v_item      RECORD;
  v_source_id UUID;
BEGIN
  SELECT * INTO v_transfer FROM public.stock_transfers WHERE id = p_transfer_id;

  IF v_transfer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfert non trouvé');
  END IF;

  IF v_transfer.status != 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Le transfert doit être en attente pour être expédié');
  END IF;

  v_source_id := COALESCE(v_transfer.source_location_id, v_transfer.from_location_id);

  FOR v_item IN SELECT * FROM public.stock_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    -- Décrément GARDÉ atomique : ne décrémente QUE si le stock disponible suffit.
    UPDATE public.location_stock
    SET quantity          = quantity - v_item.quantity_sent,
        last_stock_update = NOW(),
        updated_at        = NOW()
    WHERE location_id = v_source_id
      AND product_id  = v_item.product_id
      AND COALESCE(available_quantity, quantity, 0) >= v_item.quantity_sent;

    IF NOT FOUND THEN
      -- Stock insuffisant OU ligne inexistante → annule tout le transfert (rollback)
      RAISE EXCEPTION 'INSUFFICIENT_STOCK:%', v_item.product_id;
    END IF;

    -- Historique (lit la ligne déjà décrémentée)
    INSERT INTO public.location_stock_history (
      location_id, product_id, movement_type,
      quantity_before, quantity_change, quantity_after,
      reference_type, reference_id, performed_by, notes
    )
    SELECT
      v_source_id,
      v_item.product_id,
      'transfer_out',
      ls.quantity + v_item.quantity_sent,
      -v_item.quantity_sent,
      ls.quantity,
      'transfer',
      p_transfer_id,
      p_shipped_by,
      'Transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT)
    FROM public.location_stock ls
    WHERE ls.location_id = v_source_id
      AND ls.product_id  = v_item.product_id;
  END LOOP;

  UPDATE public.stock_transfers
  SET status         = 'in_transit',
      shipped_at     = NOW(),
      shipped_by     = p_shipped_by,
      shipping_notes = p_shipping_notes,
      updated_at     = NOW()
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object('success', true, 'transfer_id', p_transfer_id, 'status', 'in_transit');

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'INSUFFICIENT_STOCK:%' THEN
      RETURN jsonb_build_object('success', false, 'error',
        'Stock insuffisant pour le produit ' || split_part(SQLERRM, ':', 2));
    END IF;
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.ship_transfer(UUID, UUID, TEXT) TO authenticated;
