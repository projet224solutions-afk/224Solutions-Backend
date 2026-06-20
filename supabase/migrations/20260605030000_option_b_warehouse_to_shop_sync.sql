-- =====================================================================
-- OPTION B : couplage à sens unique entrepôt → boutique (stock vendable)
-- =====================================================================
-- DÉCISION : `products.stock_quantity` est la SOURCE DE VÉRITÉ UNIQUE du stock
-- VENDABLE (marketplace + POS). L'entrepôt (`location_stock`) gère le stock
-- physique en réserve. Un transfert dont la destination est une BOUTIQUE
-- (destination_type = 'shop') rend la quantité reçue VENDABLE : on incrémente
-- `products.stock_quantity` du produit boutique correspondant.
--
-- Sens UNIQUE : seules les réceptions « vers boutique » alimentent le vendable.
-- Les ventes (marketplace/POS) ne décrémentent QUE products.stock_quantity
-- (inchangé) → AUCUN risque de double comptage. Le miroir `inventory` suit
-- automatiquement (trigger sync_product_inventory).
--
-- Produit vendable ciblé = stock_transfer_items.shop_product_id si défini,
-- sinon le product_id transféré lui-même. Scopé au vendeur du transfert.
-- Idempotent : confirm_transfer_reception ne s'exécute qu'une fois (garde de
-- statut : refuse si le transfert n'est pas in_transit/delivered).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run (APRÈS 20260502300000).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.confirm_transfer_reception(
  p_transfer_id    UUID,
  p_received_items JSONB,
  p_user_id        UUID DEFAULT NULL,
  p_notes          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer       RECORD;
  v_item           JSONB;
  v_sent_item      RECORD;
  v_total_received INTEGER := 0;
  v_total_missing  INTEGER := 0;
  v_final_status   TEXT;
  v_vendor_id      UUID;
  v_loss_number    TEXT;
  v_dest_id        UUID;
  v_is_shop        BOOLEAN;
  v_shop_product   UUID;
  v_received       INTEGER;
BEGIN
  SELECT * INTO v_transfer FROM public.stock_transfers WHERE id = p_transfer_id;

  IF v_transfer IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Transfert non trouvé');
  END IF;

  IF v_transfer.status NOT IN ('in_transit', 'delivered') THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Le transfert doit être en transit pour être confirmé');
  END IF;

  v_vendor_id := v_transfer.vendor_id;
  v_dest_id   := COALESCE(v_transfer.destination_location_id, v_transfer.to_location_id);
  -- OPTION B : la destination est-elle une boutique ?
  -- Accès via to_jsonb → robuste si la colonne destination_type n'existe pas
  -- (renvoie NULL → 'warehouse' → pas de couplage). Pareil pour shop_product_id.
  v_is_shop   := (COALESCE(to_jsonb(v_transfer)->>'destination_type', 'warehouse') = 'shop');

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_received_items)
  LOOP
    SELECT * INTO v_sent_item
    FROM public.stock_transfer_items
    WHERE transfer_id = p_transfer_id
      AND product_id  = (v_item->>'product_id')::UUID;

    IF v_sent_item IS NULL THEN
      CONTINUE;
    END IF;

    v_received := (v_item->>'quantity_received')::INTEGER;

    UPDATE public.stock_transfer_items
    SET quantity_received = v_received,
        reception_notes   = v_item->>'notes',
        missing_reason    = v_item->>'missing_reason'
    WHERE id = v_sent_item.id;

    v_total_received := v_total_received + v_received;

    -- Ajouter le stock à la destination (réserve physique)
    INSERT INTO public.location_stock (location_id, product_id, quantity, cost_price)
    VALUES (v_dest_id, (v_item->>'product_id')::UUID, v_received, v_sent_item.unit_cost)
    ON CONFLICT (location_id, product_id) DO UPDATE
    SET quantity          = public.location_stock.quantity + v_received,
        last_stock_update = NOW(),
        updated_at        = NOW();

    -- Historique
    INSERT INTO public.location_stock_history (
      location_id, product_id, movement_type,
      quantity_before, quantity_change, quantity_after,
      reference_type, reference_id, performed_by, notes
    )
    SELECT
      v_dest_id, (v_item->>'product_id')::UUID, 'transfer_in',
      COALESCE(ls.quantity, 0) - v_received,
      v_received,
      COALESCE(ls.quantity, 0),
      'transfer', p_transfer_id, p_user_id,
      'Réception transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT)
    FROM public.location_stock ls
    WHERE ls.location_id = v_dest_id
      AND ls.product_id  = (v_item->>'product_id')::UUID;

    -- ★ OPTION B : si destination = boutique, rendre la quantité reçue VENDABLE
    --   (products.stock_quantity = source de vérité unique). Sens unique, 1 seul point.
    IF v_is_shop AND v_received > 0 THEN
      -- shop_product_id via to_jsonb → NULL si la colonne n'existe pas → fallback product_id
      v_shop_product := COALESCE(NULLIF(to_jsonb(v_sent_item)->>'shop_product_id', '')::uuid, (v_item->>'product_id')::UUID);
      UPDATE public.products
      SET stock_quantity = COALESCE(stock_quantity, 0) + v_received,
          updated_at     = NOW()
      WHERE id = v_shop_product AND vendor_id = v_vendor_id;
    END IF;

    -- Créer une perte si manquants
    IF v_received < v_sent_item.quantity_sent THEN
      v_loss_number := public.generate_loss_number(v_vendor_id);

      INSERT INTO public.stock_losses (
        vendor_id, loss_number, location_id, product_id,
        source_type, source_reference_id, quantity, unit_cost,
        reason, notes, reported_by
      ) VALUES (
        v_vendor_id, v_loss_number, v_dest_id, (v_item->>'product_id')::UUID,
        'transfer', p_transfer_id,
        v_sent_item.quantity_sent - v_received,
        v_sent_item.unit_cost,
        v_item->>'missing_reason',
        'Manquant lors du transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT),
        p_user_id
      );

      v_total_missing := v_total_missing + (v_sent_item.quantity_sent - v_received);
    END IF;
  END LOOP;

  IF v_total_missing = 0 THEN
    v_final_status := 'completed';
  ELSE
    v_final_status := 'partial';
  END IF;

  UPDATE public.stock_transfers
  SET status                  = v_final_status,
      confirmed_at            = NOW(),
      confirmed_by            = p_user_id,
      received_by             = p_user_id,
      received_at             = NOW(),
      reception_notes         = p_notes,
      total_items_received    = v_total_received,
      total_items_missing     = v_total_missing,
      total_quantity_received = v_total_received,
      total_quantity_lost     = v_total_missing,
      delivered_at            = COALESCE(delivered_at, NOW()),
      updated_at              = NOW()
  WHERE id = p_transfer_id;

  RETURN jsonb_build_object(
    'success',        true,
    'transfer_id',    p_transfer_id,
    'status',         v_final_status,
    'total_received', v_total_received,
    'total_missing',  v_total_missing,
    'shop_replenished', v_is_shop
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_transfer_reception(UUID, JSONB, UUID, TEXT) TO authenticated;
