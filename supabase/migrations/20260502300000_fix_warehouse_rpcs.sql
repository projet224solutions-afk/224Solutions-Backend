-- =====================================================
-- CORRECTIF SYSTÈME ENTREPÔT - COLONNES + RPCs
-- 224SOLUTIONS - 02 Mai 2026
-- =====================================================
-- Problèmes corrigés :
--   1. stock_transfers : colonnes source/destination manquantes
--   2. stock_transfer_items : colonne quantity_lost manquante
--   3. ship_transfer : mauvais noms de paramètres
--   4. receive_transfer : fonction inexistante
--   5. confirm_transfer_reception : utilise to_location_id (obsolète)
--   6. get_location_stats : utilise les anciennes colonnes
-- =====================================================

BEGIN;

-- =====================================================
-- 1. COLONNES MANQUANTES DANS stock_transfers
-- =====================================================

-- source/destination (l'ancienne migration utilisait from/to)
-- received_at, total_quantity_received, total_quantity_lost : utilisés par le hook frontend
ALTER TABLE public.stock_transfers
  ADD COLUMN IF NOT EXISTS source_location_id UUID REFERENCES public.vendor_locations(id),
  ADD COLUMN IF NOT EXISTS destination_location_id UUID REFERENCES public.vendor_locations(id),
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS expected_arrival_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS received_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS total_items INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_quantity_sent INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_quantity_received INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS total_quantity_lost INTEGER DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_stock_transfers_source_loc
  ON public.stock_transfers(source_location_id);
CREATE INDEX IF NOT EXISTS idx_stock_transfers_dest_loc
  ON public.stock_transfers(destination_location_id);

-- Backfill : remplir les nouvelles colonnes depuis les anciennes
UPDATE public.stock_transfers
SET
  source_location_id       = COALESCE(source_location_id, from_location_id),
  destination_location_id  = COALESCE(destination_location_id, to_location_id),
  created_by               = COALESCE(created_by, initiated_by),
  received_at              = COALESCE(received_at, delivered_at),
  total_items              = COALESCE(NULLIF(total_items, 0), total_items_sent, 0),
  total_quantity_sent      = COALESCE(NULLIF(total_quantity_sent, 0), total_items_sent, 0),
  total_quantity_received  = COALESCE(NULLIF(total_quantity_received, 0), total_items_received, 0),
  total_quantity_lost      = COALESCE(NULLIF(total_quantity_lost, 0), total_items_missing, 0)
WHERE source_location_id IS NULL
   OR destination_location_id IS NULL;

-- =====================================================
-- 2. COLONNE MANQUANTE DANS stock_transfer_items
-- =====================================================

-- Le trigger sync_stock_transfer_item_units référence quantity_lost
-- mais l'ancienne migration ne créait que quantity_missing
ALTER TABLE public.stock_transfer_items
  ADD COLUMN IF NOT EXISTS quantity_lost INTEGER DEFAULT 0;

-- Backfill
UPDATE public.stock_transfer_items
SET quantity_lost = COALESCE(NULLIF(quantity_lost, 0), quantity_missing, 0);

-- =====================================================
-- 3. RECRÉATION DE ship_transfer (bons noms de paramètres)
-- =====================================================
-- L'ancienne version avait p_user_id / p_notes
-- Le hook appelle p_shipped_by / p_shipping_notes

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

  -- Compatibilité : nouvelle colonne source_location_id ou ancienne from_location_id
  v_source_id := COALESCE(v_transfer.source_location_id, v_transfer.from_location_id);

  FOR v_item IN SELECT * FROM public.stock_transfer_items WHERE transfer_id = p_transfer_id
  LOOP
    -- Vérifier stock disponible
    IF (
      SELECT COALESCE(available_quantity, quantity, 0)
      FROM public.location_stock
      WHERE location_id = v_source_id AND product_id = v_item.product_id
    ) < v_item.quantity_sent THEN
      RETURN jsonb_build_object('success', false, 'error',
        'Stock insuffisant pour le produit ' || v_item.product_id::TEXT);
    END IF;

    -- Décrémenter le stock source
    UPDATE public.location_stock
    SET quantity           = quantity - v_item.quantity_sent,
        last_stock_update  = NOW(),
        updated_at         = NOW()
    WHERE location_id = v_source_id
      AND product_id  = v_item.product_id;

    -- Historique
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

  RETURN jsonb_build_object(
    'success',     true,
    'transfer_id', p_transfer_id,
    'status',      'in_transit'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.ship_transfer(UUID, UUID, TEXT) TO authenticated;

-- =====================================================
-- 4. CORRECTIF confirm_transfer_reception
-- =====================================================
-- Utilise COALESCE(destination_location_id, to_location_id) pour la rétrocompatibilité

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
  v_transfer      RECORD;
  v_item          JSONB;
  v_sent_item     RECORD;
  v_total_received INTEGER := 0;
  v_total_missing  INTEGER := 0;
  v_final_status   TEXT;
  v_vendor_id      UUID;
  v_loss_number    TEXT;
  v_dest_id        UUID;
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
  -- Compatibilité nouvelle/ancienne colonne
  v_dest_id   := COALESCE(v_transfer.destination_location_id, v_transfer.to_location_id);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_received_items)
  LOOP
    SELECT * INTO v_sent_item
    FROM public.stock_transfer_items
    WHERE transfer_id = p_transfer_id
      AND product_id  = (v_item->>'product_id')::UUID;

    IF v_sent_item IS NULL THEN
      CONTINUE;
    END IF;

    UPDATE public.stock_transfer_items
    SET quantity_received = (v_item->>'quantity_received')::INTEGER,
        reception_notes   = v_item->>'notes',
        missing_reason    = v_item->>'missing_reason'
    WHERE id = v_sent_item.id;

    v_total_received := v_total_received + (v_item->>'quantity_received')::INTEGER;

    -- Ajouter le stock à la destination
    INSERT INTO public.location_stock (location_id, product_id, quantity, cost_price)
    VALUES (
      v_dest_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity_received')::INTEGER,
      v_sent_item.unit_cost
    )
    ON CONFLICT (location_id, product_id) DO UPDATE
    SET quantity          = public.location_stock.quantity + (v_item->>'quantity_received')::INTEGER,
        last_stock_update = NOW(),
        updated_at        = NOW();

    -- Historique
    INSERT INTO public.location_stock_history (
      location_id, product_id, movement_type,
      quantity_before, quantity_change, quantity_after,
      reference_type, reference_id, performed_by, notes
    )
    SELECT
      v_dest_id,
      (v_item->>'product_id')::UUID,
      'transfer_in',
      COALESCE(ls.quantity, 0) - (v_item->>'quantity_received')::INTEGER,
      (v_item->>'quantity_received')::INTEGER,
      COALESCE(ls.quantity, 0),
      'transfer',
      p_transfer_id,
      p_user_id,
      'Réception transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT)
    FROM public.location_stock ls
    WHERE ls.location_id = v_dest_id
      AND ls.product_id  = (v_item->>'product_id')::UUID;

    -- Créer une perte si manquants
    IF (v_item->>'quantity_received')::INTEGER < v_sent_item.quantity_sent THEN
      v_loss_number := public.generate_loss_number(v_vendor_id);

      INSERT INTO public.stock_losses (
        vendor_id, loss_number, location_id, product_id,
        source_type, source_reference_id, quantity, unit_cost,
        reason, notes, reported_by
      ) VALUES (
        v_vendor_id,
        v_loss_number,
        v_dest_id,
        (v_item->>'product_id')::UUID,
        'transfer',
        p_transfer_id,
        v_sent_item.quantity_sent - (v_item->>'quantity_received')::INTEGER,
        v_sent_item.unit_cost,
        v_item->>'missing_reason',
        'Manquant lors du transfert ' || COALESCE(v_transfer.transfer_number, p_transfer_id::TEXT),
        p_user_id
      );

      v_total_missing := v_total_missing +
        (v_sent_item.quantity_sent - (v_item->>'quantity_received')::INTEGER);
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
    'total_missing',  v_total_missing
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.confirm_transfer_reception(UUID, JSONB, UUID, TEXT) TO authenticated;

-- =====================================================
-- 5. CRÉATION DE receive_transfer (alias avec nouveaux paramètres)
-- =====================================================
-- Le hook appelle receive_transfer avec p_items_received / p_received_by / p_reception_notes
-- La fonction délègue à confirm_transfer_reception

CREATE OR REPLACE FUNCTION public.receive_transfer(
  p_transfer_id    UUID,
  p_items_received JSONB,
  p_received_by    UUID DEFAULT NULL,
  p_reception_notes TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN public.confirm_transfer_reception(
    p_transfer_id    := p_transfer_id,
    p_received_items := p_items_received,
    p_user_id        := p_received_by,
    p_notes          := p_reception_notes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.receive_transfer(UUID, JSONB, UUID, TEXT) TO authenticated;

-- =====================================================
-- 6. CORRECTIF get_location_stats (nouvelles colonnes)
-- =====================================================

CREATE OR REPLACE FUNCTION public.get_location_stats(p_location_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT jsonb_build_object(
    'location_id',           p_location_id,
    'total_products',        COUNT(DISTINCT ls.product_id),
    'total_quantity',        COALESCE(SUM(ls.quantity), 0),
    'total_value',           COALESCE(SUM(ls.quantity * ls.cost_price), 0),
    'low_stock_count',       COUNT(*) FILTER (WHERE ls.quantity <= ls.minimum_stock AND ls.quantity > 0),
    'out_of_stock_count',    COUNT(*) FILTER (WHERE ls.quantity = 0),
    'pending_transfers_in',  (
      SELECT COUNT(*) FROM public.stock_transfers
      WHERE COALESCE(destination_location_id, to_location_id) = p_location_id
        AND status = 'in_transit'
    ),
    'pending_transfers_out', (
      SELECT COUNT(*) FROM public.stock_transfers
      WHERE COALESCE(source_location_id, from_location_id) = p_location_id
        AND status IN ('pending', 'in_transit')
    )
  ) INTO v_result
  FROM public.location_stock ls
  WHERE ls.location_id = p_location_id;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_location_stats(UUID) TO authenticated;

-- =====================================================
-- 7. CORRECTIF create_stock_transfer (fallback du hook)
-- =====================================================
-- L'ancienne migration utilisait from_location_id/to_location_id
-- Recréer pour utiliser source_location_id/destination_location_id

CREATE OR REPLACE FUNCTION public.create_stock_transfer(
  p_vendor_id              UUID,
  p_source_location_id     UUID,
  p_destination_location_id UUID,
  p_items                  JSONB,
  p_notes                  TEXT    DEFAULT NULL,
  p_created_by             UUID    DEFAULT NULL,
  p_expected_arrival       TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_transfer_id     UUID;
  v_transfer_number TEXT;
  v_item            JSONB;
  v_total_items     INTEGER := 0;
  v_total_value     DECIMAL := 0;
BEGIN
  IF COALESCE(JSONB_ARRAY_LENGTH(p_items), 0) = 0 THEN
    RAISE EXCEPTION 'Aucun article à transférer';
  END IF;

  IF p_source_location_id = p_destination_location_id THEN
    RAISE EXCEPTION 'La source et la destination doivent être différentes';
  END IF;

  v_transfer_number := public.generate_transfer_number(p_vendor_id);

  INSERT INTO public.stock_transfers (
    vendor_id, transfer_number,
    source_location_id, destination_location_id,
    from_location_id, to_location_id,
    destination_type, status, approval_status,
    notes, created_by, initiated_by,
    expected_arrival_at
  ) VALUES (
    p_vendor_id, v_transfer_number,
    p_source_location_id, p_destination_location_id,
    p_source_location_id, p_destination_location_id,
    'warehouse', 'pending', 'approved',
    p_notes, p_created_by, p_created_by,
    p_expected_arrival
  )
  RETURNING id INTO v_transfer_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.stock_transfer_items (
      transfer_id, product_id,
      quantity_sent, quantity_received, quantity_lost,
      unit_cost
    ) VALUES (
      v_transfer_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity')::INTEGER,
      0,
      0,
      COALESCE((v_item->>'unit_cost')::DECIMAL, 0)
    );

    v_total_items := v_total_items + (v_item->>'quantity')::INTEGER;
    v_total_value := v_total_value +
      ((v_item->>'quantity')::INTEGER * COALESCE((v_item->>'unit_cost')::DECIMAL, 0));
  END LOOP;

  UPDATE public.stock_transfers
  SET total_items        = v_total_items,
      total_items_sent   = v_total_items,
      total_quantity_sent = v_total_items,
      total_value        = v_total_value
  WHERE id = v_transfer_id;

  RETURN v_transfer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_stock_transfer(UUID, UUID, UUID, JSONB, TEXT, UUID, TIMESTAMPTZ)
  TO authenticated;

-- =====================================================
-- 8. RLS POUR warehouse_shop_product_links
-- =====================================================
-- La migration de l'extension professionnelle crée la table mais pas la RLS

ALTER TABLE public.warehouse_shop_product_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Vendors can manage their shop product links" ON public.warehouse_shop_product_links;
CREATE POLICY "Vendors can manage their shop product links"
  ON public.warehouse_shop_product_links
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = warehouse_shop_product_links.vendor_id
        AND v.user_id = auth.uid()
    )
  );

-- RLS pour warehouse_audit_logs
ALTER TABLE public.warehouse_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Vendors can view their audit logs" ON public.warehouse_audit_logs;
CREATE POLICY "Vendors can view their audit logs"
  ON public.warehouse_audit_logs
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.vendors v
      WHERE v.id = warehouse_audit_logs.vendor_id
        AND v.user_id = auth.uid()
    )
  );

COMMIT;
