-- ============================================================================
-- DROPSHIPPING — Phase 2 : FULFILLMENT AUTOMATIQUE (façon Shopify)
-- ----------------------------------------------------------------------------
-- À la commande client PAYÉE contenant un produit dropship (produit catalogue lié
-- à un dropship_product via published_product_id), on crée AUTOMATIQUEMENT la
-- commande fournisseur (`dropship_orders`) — comme Shopify/DSers passent la commande
-- au fournisseur dès le paiement. Le PLACEMENT réel chez le fournisseur (appel API)
-- viendra en Phase 3 (connecteurs backend) ; ici la commande fournisseur est créée en
-- statut 'pending' (prête à être transmise).
--
-- Idempotent (1 dropship_order par couple commande↔produit dropship). DÉFENSIF : toute
-- erreur de fulfillment est capturée (RAISE WARNING) → ne casse JAMAIS la commande client.
-- Couvre les paiements SYNCHRONES (create_order_core insère order payé puis items) ET
-- ASYNCHRONES (order créé 'pending' puis payment_status passe à 'paid' via webhook).
-- SECURITY DEFINER. Rejouable.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fulfill_dropship_for_order(p_order_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pay      text;
  v_ship     jsonb;
  v_currency text;
  v_count    int := 0;
  rec        record;
  v_qty      numeric;
  v_sup_unit numeric;
  v_sell_unit numeric;
  v_sup_total numeric;
  v_cust_total numeric;
  v_vendor   uuid;
BEGIN
  SELECT payment_status, shipping_address, currency
    INTO v_pay, v_ship, v_currency
  FROM public.orders WHERE id = p_order_id;

  IF NOT FOUND OR v_pay <> 'paid' THEN
    RETURN 0; -- pas payé → on ne transmet rien au fournisseur
  END IF;

  FOR rec IN
    SELECT oi.quantity, oi.unit_price, oi.total_price, oi.product_name,
           dp.id AS dp_id, dp.vendor_id AS dp_vendor, dp.supplier_id,
           dp.supplier_price, dp.cost_price, dp.supplier_currency, dp.cost_currency,
           dp.selling_price, dp.selling_currency, dp.title
    FROM public.order_items oi
    JOIN public.dropship_products dp ON dp.published_product_id = oi.product_id
    WHERE oi.order_id = p_order_id
  LOOP
    -- Idempotence : déjà une commande fournisseur pour ce couple ?
    IF EXISTS (
      SELECT 1 FROM public.dropship_orders
      WHERE customer_order_id = p_order_id AND dropship_product_id = rec.dp_id
    ) THEN
      CONTINUE;
    END IF;

    v_qty       := COALESCE(rec.quantity, 1);
    v_sup_unit  := COALESCE(rec.supplier_price, rec.cost_price, 0);
    v_sell_unit := COALESCE(rec.selling_price, rec.unit_price, 0);
    v_sup_total := v_sup_unit * v_qty;
    v_cust_total := COALESCE(rec.total_price, v_sell_unit * v_qty);
    v_vendor    := public.resolve_vendor_id(rec.dp_vendor);

    INSERT INTO public.dropship_orders (
      customer_order_id, vendor_id, supplier_id, dropship_product_id,
      items, quantity,
      supplier_total, supplier_currency,
      customer_total, customer_currency,
      profit_amount, shipping_address, status, vendor_payment_status
    ) VALUES (
      p_order_id, v_vendor, rec.supplier_id, rec.dp_id,
      jsonb_build_array(jsonb_build_object(
        'dropship_product_id', rec.dp_id,
        'product_name', COALESCE(rec.title, rec.product_name),
        'quantity', v_qty,
        'supplier_unit_price', v_sup_unit,
        'selling_unit_price', v_sell_unit
      )),
      v_qty,
      v_sup_total, COALESCE(NULLIF(rec.supplier_currency,''), NULLIF(rec.cost_currency,''), 'USD'),
      v_cust_total, COALESCE(NULLIF(v_currency,''), NULLIF(rec.selling_currency,''), 'USD'),
      v_cust_total - v_sup_total, v_ship, 'pending', 'pending'
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

-- ── Trigger 1 : commande passe à 'paid' (couvre paiement ASYNCHRONE / webhook) ──
CREATE OR REPLACE FUNCTION public.trg_dropship_fulfill_order()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.payment_status = 'paid'
     AND (TG_OP = 'INSERT' OR OLD.payment_status IS DISTINCT FROM 'paid') THEN
    BEGIN
      PERFORM public.fulfill_dropship_for_order(NEW.id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'dropship fulfill (order %) ignoré: %', NEW.id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_dropship_fulfill ON public.orders;
CREATE TRIGGER trg_orders_dropship_fulfill
  AFTER INSERT OR UPDATE OF payment_status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.trg_dropship_fulfill_order();

-- ── Trigger 2 : item inséré sur une commande déjà payée (couvre create_order_core,
--    qui insère l'order payé PUIS les items → l'AFTER INSERT order serait trop tôt) ──
CREATE OR REPLACE FUNCTION public.trg_dropship_fulfill_item()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v_paid text;
BEGIN
  -- Court-circuit : ne rien faire si l'item n'est pas un produit dropship (cas majoritaire).
  IF NOT EXISTS (
    SELECT 1 FROM public.dropship_products WHERE published_product_id = NEW.product_id
  ) THEN
    RETURN NEW;
  END IF;

  SELECT payment_status INTO v_paid FROM public.orders WHERE id = NEW.order_id;
  IF v_paid = 'paid' THEN
    BEGIN
      PERFORM public.fulfill_dropship_for_order(NEW.order_id);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'dropship fulfill (item, order %) ignoré: %', NEW.order_id, SQLERRM;
    END;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_order_items_dropship_fulfill ON public.order_items;
CREATE TRIGGER trg_order_items_dropship_fulfill
  AFTER INSERT ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.trg_dropship_fulfill_item();

GRANT EXECUTE ON FUNCTION public.fulfill_dropship_for_order(uuid) TO service_role;

SELECT 'Fulfillment auto dropship installé (RPC fulfill_dropship_for_order + 2 triggers défensifs).' AS status;
