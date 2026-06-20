-- =====================================================================
-- FIX : double décrément du stock à la commande + atomicité inventaire
-- =====================================================================
-- BUG : à la création d'une commande marketplace, le stock était décrémenté
-- DEUX FOIS :
--   1. par create_order_core (PHASE 4 : UPDATE products SET stock = stock - qty)
--   2. par le trigger decrement_stock_on_order_items (AFTER INSERT ON order_items)
-- → chaque vente sur-décrémentait ; et à l'ANNULATION (increment_stock_batch,
--   +qty une seule fois) le stock finissait PLUS BAS qu'avant l'achat.
-- Le POS (source='pos') n'a pas de décrément explicite et dépend du trigger.
--
-- CORRECTIF :
--   - Le trigger ne décrémente QUE pour les ventes non-marketplace (POS) ;
--     les commandes 'online' sont déjà décrémentées par create_order_core.
--   - `inventory.quantity` n'est plus modifié directement par ce trigger :
--     il est maintenu en miroir de products.stock_quantity par
--     sync_product_inventory (même transaction → atomique), couvrant TOUS
--     les changements de stock (commande, POS, restock annulation…).
--
-- À exécuter dans Supabase Dashboard → SQL Editor → Run. Idempotent.
-- =====================================================================

-- 1) Inventaire = miroir atomique de products.stock_quantity
CREATE OR REPLACE FUNCTION public.sync_product_inventory()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.inventory (product_id, quantity, last_updated)
  VALUES (NEW.id, COALESCE(NEW.stock_quantity, 0), now())
  ON CONFLICT (product_id) DO UPDATE
    SET quantity = EXCLUDED.quantity, last_updated = now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_sync_product_inventory ON public.products;
CREATE TRIGGER trg_sync_product_inventory
  AFTER INSERT OR UPDATE OF stock_quantity ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.sync_product_inventory();

-- 2) Décrément stock à la commande : uniquement pour les ventes NON-'online'
--    (le marketplace 'online' est déjà géré par create_order_core).
--    Ne touche plus `inventory` (synchronisé par le trigger ci-dessus).
CREATE OR REPLACE FUNCTION public.decrement_stock_on_order_items()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_source text;
BEGIN
  SELECT source INTO v_source FROM public.orders WHERE id = NEW.order_id;

  IF v_source IS DISTINCT FROM 'online' THEN
    UPDATE public.products
    SET stock_quantity = GREATEST(0, COALESCE(stock_quantity, 0) - NEW.quantity),
        updated_at = NOW()
    WHERE id = NEW.product_id;
  END IF;

  RETURN NEW;
END;
$$;

-- 2bis) Restauration du stock à l'ANNULATION — couvre TOUS les chemins
--   (backend /cancel, mise à jour directe du statut côté client/vendeur/POS).
--   Restaure une seule fois, au passage status → 'cancelled'.
--   ⚠️ increment_stock_batch est retiré des routes backend pour éviter un double.
CREATE OR REPLACE FUNCTION public.restore_stock_on_order_cancel()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.status = 'cancelled' AND OLD.status IS DISTINCT FROM 'cancelled' THEN
    UPDATE public.products p
    SET stock_quantity = COALESCE(p.stock_quantity, 0) + oi.qty,
        updated_at = NOW()
    FROM (
      SELECT product_id, SUM(quantity) AS qty
      FROM public.order_items
      WHERE order_id = NEW.id
      GROUP BY product_id
    ) oi
    WHERE p.id = oi.product_id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_restore_stock_on_order_cancel ON public.orders;
CREATE TRIGGER trg_restore_stock_on_order_cancel
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.restore_stock_on_order_cancel();

-- 3) Backfill : aligner l'inventaire existant sur products.stock_quantity
INSERT INTO public.inventory (product_id, quantity, last_updated)
SELECT id, COALESCE(stock_quantity, 0), now()
FROM public.products
ON CONFLICT (product_id) DO UPDATE
  SET quantity = EXCLUDED.quantity, last_updated = now();
