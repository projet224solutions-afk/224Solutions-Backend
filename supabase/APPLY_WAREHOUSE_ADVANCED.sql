-- ============================================================
-- 224SOLUTIONS — Entrepôt avancé (robuste au schéma partiel)
-- Vérifié live : ship_transfer/confirm_transfer_reception + colonnes existent.
-- 1) ship_transfer : fix TOCTOU (décrément gardé atomique).
-- 2) confirm_transfer_reception : Option B entrepôt→boutique (robuste via to_jsonb
--    pour destination_type/shop_product_id si colonnes absentes).
-- 3) sync_location_stock_units : unification cartons — GARDÉE (no-op si
--    units_per_carton absent, càd tant que l'extension cartons n'est pas posée).
-- À coller en UNE fois dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- ============================================================


-- ===== 20260605010000_fix_ship_transfer_toctou =====
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


-- ===== 20260605030000_option_b_warehouse_to_shop_sync =====
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


-- ===== 20260605040000_unify_location_stock_quantity_model =====
-- =====================================================================
-- UNIFICATION du double modèle de quantité de location_stock
-- =====================================================================
-- BUG : le trigger sync_location_stock_units (migration 20260409123000)
-- recalculait toujours `quantity := total_units` (total_units dérivé des
-- cartons). Conséquence : toute écriture DIRECTE sur `quantity` — ce que font
-- TOUTES les RPC entrepôt (ship_transfer, confirm_transfer_reception,
-- adjust_location_stock_atomic) — était ÉCRASÉE par l'ancienne valeur de
-- total_units dès que les cartons/total_units étaient peuplés → décréments /
-- incréments de stock PERDUS → stock entrepôt faux.
--
-- CORRECTIF (« do-what-I-mean ») : la DIMENSION MODIFIÉE devient l'autoritaire ;
-- les autres en dérivent. `quantity` et `total_units` restent toujours égaux.
--   - cartons/unités modifiés → total_units = cartons×upc + unités
--   - total_units modifié     → cartons/unités dérivés de total_units
--   - quantity modifié (RPC)  → total_units = quantity, cartons/unités dérivés
-- Sur INSERT : priorité cartons/unités, puis total_units, puis quantity.
-- `quantity` reste le miroir de total_units (compat héritée) ;
-- available_quantity = total_units − reserved_quantity.
--
-- Aucune réécriture de données : l'ancien trigger forçait déjà quantity=total_units
-- sur chaque écriture, donc les lignes existantes sont déjà cohérentes ; ce fix
-- empêche les pertes FUTURES. Idempotent.
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run (APRÈS 20260409123000).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.sync_location_stock_units()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.units_per_carton        := GREATEST(COALESCE(NEW.units_per_carton, 1), 1);
  NEW.quantity_cartons_closed := GREATEST(COALESCE(NEW.quantity_cartons_closed, 0), 0);
  NEW.quantity_units_loose    := GREATEST(COALESCE(NEW.quantity_units_loose, 0), 0);

  IF TG_OP = 'UPDATE' THEN
    -- La dimension qui a CHANGÉ fait foi
    IF NEW.quantity_cartons_closed IS DISTINCT FROM OLD.quantity_cartons_closed
       OR NEW.quantity_units_loose IS DISTINCT FROM OLD.quantity_units_loose THEN
      NEW.total_units := (NEW.quantity_cartons_closed * NEW.units_per_carton) + NEW.quantity_units_loose;

    ELSIF NEW.total_units IS DISTINCT FROM OLD.total_units THEN
      NEW.total_units             := GREATEST(COALESCE(NEW.total_units, 0), 0);
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);

    ELSIF NEW.quantity IS DISTINCT FROM OLD.quantity THEN
      -- Les RPC entrepôt écrivent ici → quantity autoritaire
      NEW.total_units             := GREATEST(COALESCE(NEW.quantity, 0), 0);
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);

    ELSE
      -- ni quantity ni total ni cartons changés (ex : units_per_carton/reserved)
      NEW.total_units := (NEW.quantity_cartons_closed * NEW.units_per_carton) + NEW.quantity_units_loose;
    END IF;

  ELSE
    -- INSERT : priorité cartons/unités, puis total_units, puis quantity
    IF NEW.quantity_cartons_closed > 0 OR NEW.quantity_units_loose > 0 THEN
      NEW.total_units := (NEW.quantity_cartons_closed * NEW.units_per_carton) + NEW.quantity_units_loose;
    ELSIF COALESCE(NEW.total_units, 0) > 0 THEN
      NEW.total_units             := NEW.total_units;
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);
    ELSE
      NEW.total_units             := GREATEST(COALESCE(NEW.quantity, 0), 0);
      NEW.quantity_cartons_closed := FLOOR(NEW.total_units / NEW.units_per_carton);
      NEW.quantity_units_loose    := MOD(NEW.total_units, NEW.units_per_carton);
    END IF;
  END IF;

  -- quantity = miroir de total_units (compat héritée) ; available = total − réservé
  NEW.quantity           := COALESCE(NEW.total_units, 0);
  NEW.available_quantity := GREATEST(COALESCE(NEW.total_units, 0) - COALESCE(NEW.reserved_quantity, 0), 0);
  RETURN NEW;
END;
$$;

-- Recréer le trigger (même périmètre de colonnes) — UNIQUEMENT si le modèle
-- cartons/unités existe (extension multi-entrepôts 20260409123000 appliquée).
-- Sinon ce fix n'a pas lieu d'être (pas de double modèle) → on saute.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'location_stock'
      AND column_name = 'units_per_carton'
  ) THEN
    DROP TRIGGER IF EXISTS trigger_sync_location_stock_units ON public.location_stock;
    CREATE TRIGGER trigger_sync_location_stock_units
      BEFORE INSERT OR UPDATE OF units_per_carton, quantity_cartons_closed, quantity_units_loose, total_units, quantity, reserved_quantity
      ON public.location_stock
      FOR EACH ROW
      EXECUTE FUNCTION public.sync_location_stock_units();
  ELSE
    RAISE NOTICE 'location_stock.units_per_carton absent → trigger non recréé (extension multi-entrepôts 20260409123000 non appliquée).';
  END IF;
END $$;
