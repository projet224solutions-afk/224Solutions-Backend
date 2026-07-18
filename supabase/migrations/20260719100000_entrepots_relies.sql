-- ============================================================
-- 🏬 ENTREPÔTS RELIÉS AU STOCK — fin du module orphelin
--
-- AUDIT (18/07) : l'écran Entrepôts lit warehouses/warehouse_stocks/
-- stock_movements — tables et RLS en place mais 0 ligne : AUCUN flux
-- (POS, marketplace, réception d'achat, B2B) n'y écrit. Le transfert
-- frontend était non-atomique et sans garde de solde. Un 3e système
-- (locations/location_stock + RPC pos_sale_from_location…) est aussi
-- orphelin — non réutilisé ici (l'écran ne le lit pas), consolidation
-- future possible.
--
-- MODÈLE CHOISI (documenté) :
--  - products.stock_quantity RESTE la source du stock GLOBAL (tous les
--    flux existants y écrivent déjà : POS, validate_stock_purchase,
--    réception B2B, marketplace, ajustements).
--  - warehouse_stocks = la RÉPARTITION par entrepôt, maintenue par
--    TRIGGER sur products : chaque delta de stock_quantity est routé
--    vers l'entrepôt PAR DÉFAUT (entrées) ou prélevé défaut→autres
--    (sorties), et JOURNALISÉ dans stock_movements.
--  - INVARIANT : Σ warehouse_stocks(produit) = products.stock_quantity —
--    vérifiable par RPC (warehouse_invariant_report), réparable
--    (reconcile_warehouse_stock).
--  - Transfert inter-entrepôts = RPC ATOMIQUE (ne touche PAS le global).
-- ============================================================

-- 1) Entrepôt PAR DÉFAUT
ALTER TABLE public.warehouses ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false;
CREATE UNIQUE INDEX IF NOT EXISTS warehouses_one_default_per_vendor
  ON public.warehouses (vendor_id) WHERE is_default;

-- Trouve (ou crée) l'entrepôt par défaut d'un vendeur. Auto-réparant :
-- marque le plus ancien actif sinon crée « Boutique principale ».
CREATE OR REPLACE FUNCTION public.ensure_default_warehouse(p_vendor_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM public.warehouses
   WHERE vendor_id = p_vendor_id AND is_default LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;

  SELECT id INTO v_id FROM public.warehouses
   WHERE vendor_id = p_vendor_id AND coalesce(is_active, true)
   ORDER BY created_at ASC LIMIT 1;
  IF v_id IS NOT NULL THEN
    UPDATE public.warehouses SET is_default = true WHERE id = v_id;
    RETURN v_id;
  END IF;

  INSERT INTO public.warehouses (vendor_id, name, is_active, is_default)
  VALUES (p_vendor_id, 'Boutique principale', true, true)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.ensure_default_warehouse(uuid) FROM PUBLIC, anon, authenticated;

-- 2) ROUTAGE DES DELTAS : trigger sur products.stock_quantity
CREATE OR REPLACE FUNCTION public.route_stock_delta_to_warehouse()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_delta integer;
  v_default uuid;
  v_remaining integer;
  v_take integer;
  r record;
BEGIN
  -- Opérations qui gèrent elles-mêmes la répartition (ajustement ciblé, réconciliation)
  IF current_setting('app.skip_warehouse_sync', true) = '1' THEN RETURN NEW; END IF;

  v_delta := coalesce(NEW.stock_quantity, 0) - coalesce(CASE WHEN TG_OP = 'UPDATE' THEN OLD.stock_quantity END, 0);
  IF v_delta = 0 OR NEW.vendor_id IS NULL THEN RETURN NEW; END IF;

  v_default := public.ensure_default_warehouse(NEW.vendor_id);

  IF v_delta > 0 THEN
    -- ENTRÉE → entrepôt par défaut
    INSERT INTO public.warehouse_stocks (warehouse_id, product_id, quantity)
    VALUES (v_default, NEW.id, v_delta)
    ON CONFLICT (warehouse_id, product_id)
    DO UPDATE SET quantity = warehouse_stocks.quantity + EXCLUDED.quantity, updated_at = now();
    INSERT INTO public.stock_movements (product_id, to_warehouse_id, quantity, movement_type, notes, created_by)
    VALUES (NEW.id, v_default, v_delta, 'in', 'sync stock global (+)', auth.uid());
  ELSE
    -- SORTIE → prélever au défaut d'abord, puis les autres entrepôts.
    v_remaining := -v_delta;
    FOR r IN
      SELECT ws.warehouse_id, ws.quantity
        FROM public.warehouse_stocks ws
       WHERE ws.product_id = NEW.id AND ws.quantity > 0
       ORDER BY (ws.warehouse_id = v_default) DESC, ws.quantity DESC
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_take := LEAST(r.quantity, v_remaining);
      UPDATE public.warehouse_stocks
         SET quantity = quantity - v_take, updated_at = now()
       WHERE warehouse_id = r.warehouse_id AND product_id = NEW.id;
      INSERT INTO public.stock_movements (product_id, from_warehouse_id, quantity, movement_type, notes, created_by)
      VALUES (NEW.id, r.warehouse_id, v_take, 'out', 'sync stock global (−)', auth.uid());
      v_remaining := v_remaining - v_take;
    END LOOP;
    -- Reste non couvert (invariant déjà cassé avant) → le rapport de
    -- réconciliation le signalera ; on ne crée jamais de stock négatif.
  END IF;

  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.route_stock_delta_to_warehouse() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_route_stock_delta_to_warehouse ON public.products;
CREATE TRIGGER trg_route_stock_delta_to_warehouse
  AFTER INSERT OR UPDATE OF stock_quantity ON public.products
  FOR EACH ROW
  WHEN (pg_trigger_depth() < 2)
  EXECUTE FUNCTION public.route_stock_delta_to_warehouse();

-- 3) BACKFILL : tout le stock existant → entrepôt par défaut de chaque vendeur
DO $$
DECLARE r record; v_default uuid;
BEGIN
  FOR r IN
    SELECT p.id AS product_id, p.vendor_id, p.stock_quantity
      FROM public.products p
     WHERE p.is_active = true
       AND coalesce(p.stock_quantity, 0) > 0
       AND p.vendor_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.warehouse_stocks ws WHERE ws.product_id = p.id)
  LOOP
    v_default := public.ensure_default_warehouse(r.vendor_id);
    INSERT INTO public.warehouse_stocks (warehouse_id, product_id, quantity)
    VALUES (v_default, r.product_id, r.stock_quantity)
    ON CONFLICT (warehouse_id, product_id) DO NOTHING;
    INSERT INTO public.stock_movements (product_id, to_warehouse_id, quantity, movement_type, notes)
    VALUES (r.product_id, v_default, r.stock_quantity, 'in', 'reprise initiale (backfill entrepôts)');
  END LOOP;
END $$;

-- 4) TRANSFERT ATOMIQUE inter-entrepôts (ne touche pas le stock global)
CREATE OR REPLACE FUNCTION public.transfer_warehouse_stock(
  p_product_id uuid,
  p_from_warehouse_id uuid,
  p_to_warehouse_id uuid,
  p_quantity integer,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_vendor uuid;
  v_from_qty integer;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'quantity_invalid');
  END IF;
  IF p_from_warehouse_id = p_to_warehouse_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'same_warehouse');
  END IF;

  -- Autorisation : l'appelant est le vendeur propriétaire des DEUX entrepôts et du produit.
  SELECT v.id INTO v_vendor FROM public.vendors v WHERE v.user_id = auth.uid() LIMIT 1;
  IF v_vendor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'not_vendor'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id = p_from_warehouse_id AND w.vendor_id = v_vendor)
     OR NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id = p_to_warehouse_id AND w.vendor_id = v_vendor)
     OR NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = p_product_id AND p.vendor_id = v_vendor) THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;

  -- Verrou + garde de solde
  SELECT quantity INTO v_from_qty FROM public.warehouse_stocks
   WHERE warehouse_id = p_from_warehouse_id AND product_id = p_product_id
   FOR UPDATE;
  IF v_from_qty IS NULL OR v_from_qty < p_quantity THEN
    RETURN jsonb_build_object('success', false, 'error', 'insufficient_stock', 'available', coalesce(v_from_qty, 0));
  END IF;

  UPDATE public.warehouse_stocks
     SET quantity = quantity - p_quantity, updated_at = now()
   WHERE warehouse_id = p_from_warehouse_id AND product_id = p_product_id;

  INSERT INTO public.warehouse_stocks (warehouse_id, product_id, quantity)
  VALUES (p_to_warehouse_id, p_product_id, p_quantity)
  ON CONFLICT (warehouse_id, product_id)
  DO UPDATE SET quantity = warehouse_stocks.quantity + EXCLUDED.quantity, updated_at = now();

  INSERT INTO public.stock_movements (product_id, from_warehouse_id, to_warehouse_id, quantity, movement_type, notes, created_by)
  VALUES (p_product_id, p_from_warehouse_id, p_to_warehouse_id, p_quantity, 'transfer', p_notes, auth.uid());

  RETURN jsonb_build_object('success', true);
END $$;
REVOKE ALL ON FUNCTION public.transfer_warehouse_stock(uuid, uuid, uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transfer_warehouse_stock(uuid, uuid, uuid, integer, text) TO authenticated, service_role;

-- 5) AJUSTEMENT PAR ENTREPÔT (motif obligatoire) — répercute le global SANS
--    repasser par le routage (flag de session), tout reste journalisé.
CREATE OR REPLACE FUNCTION public.adjust_warehouse_stock(
  p_warehouse_id uuid,
  p_product_id uuid,
  p_new_quantity integer,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_vendor uuid;
  v_old integer;
  v_delta integer;
BEGIN
  IF p_new_quantity IS NULL OR p_new_quantity < 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'quantity_invalid');
  END IF;
  IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'reason_required');
  END IF;

  SELECT v.id INTO v_vendor FROM public.vendors v WHERE v.user_id = auth.uid() LIMIT 1;
  IF v_vendor IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'not_vendor'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.warehouses w WHERE w.id = p_warehouse_id AND w.vendor_id = v_vendor)
     OR NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = p_product_id AND p.vendor_id = v_vendor) THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;

  SELECT quantity INTO v_old FROM public.warehouse_stocks
   WHERE warehouse_id = p_warehouse_id AND product_id = p_product_id FOR UPDATE;
  v_old := coalesce(v_old, 0);
  v_delta := p_new_quantity - v_old;
  IF v_delta = 0 THEN RETURN jsonb_build_object('success', true, 'unchanged', true); END IF;

  INSERT INTO public.warehouse_stocks (warehouse_id, product_id, quantity)
  VALUES (p_warehouse_id, p_product_id, p_new_quantity)
  ON CONFLICT (warehouse_id, product_id)
  DO UPDATE SET quantity = EXCLUDED.quantity, updated_at = now();

  -- Répercuter le GLOBAL (invariant) sans double-routage.
  PERFORM set_config('app.skip_warehouse_sync', '1', true);
  UPDATE public.products
     SET stock_quantity = GREATEST(0, coalesce(stock_quantity, 0) + v_delta)
   WHERE id = p_product_id;
  PERFORM set_config('app.skip_warehouse_sync', '0', true);

  INSERT INTO public.stock_movements (product_id, from_warehouse_id, to_warehouse_id, quantity, movement_type, notes, created_by)
  VALUES (
    p_product_id,
    CASE WHEN v_delta < 0 THEN p_warehouse_id END,
    CASE WHEN v_delta > 0 THEN p_warehouse_id END,
    abs(v_delta),
    CASE WHEN v_delta > 0 THEN 'in' ELSE 'out' END,
    'ajustement : ' || trim(p_reason),
    auth.uid()
  );

  RETURN jsonb_build_object('success', true, 'previous', v_old, 'new', p_new_quantity);
END $$;
REVOKE ALL ON FUNCTION public.adjust_warehouse_stock(uuid, uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_warehouse_stock(uuid, uuid, integer, text) TO authenticated, service_role;

-- 6) INVARIANT : rapport + réconciliation
CREATE OR REPLACE FUNCTION public.warehouse_invariant_report(p_vendor_id uuid)
RETURNS TABLE (product_id uuid, product_name text, global_stock integer, warehouse_sum bigint, gap bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT p.id, p.name, coalesce(p.stock_quantity, 0),
         coalesce(SUM(ws.quantity), 0)::bigint,
         (coalesce(p.stock_quantity, 0) - coalesce(SUM(ws.quantity), 0))::bigint
    FROM public.products p
    LEFT JOIN public.warehouse_stocks ws ON ws.product_id = p.id
   WHERE p.vendor_id = p_vendor_id AND p.is_active = true
   GROUP BY p.id, p.name, p.stock_quantity
  HAVING coalesce(p.stock_quantity, 0) <> coalesce(SUM(ws.quantity), 0);
$$;
REVOKE ALL ON FUNCTION public.warehouse_invariant_report(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.warehouse_invariant_report(uuid) TO authenticated, service_role;

-- Réconciliation : aligne l'entrepôt PAR DÉFAUT sur l'écart (jamais silencieux : mouvement tracé).
CREATE OR REPLACE FUNCTION public.reconcile_warehouse_stock(p_vendor_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_vendor uuid;
  v_default uuid;
  r record;
  v_fixed integer := 0;
BEGIN
  SELECT v.id INTO v_vendor FROM public.vendors v WHERE v.user_id = auth.uid() LIMIT 1;
  IF v_vendor IS NULL OR v_vendor <> p_vendor_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_owner');
  END IF;
  v_default := public.ensure_default_warehouse(p_vendor_id);

  FOR r IN SELECT * FROM public.warehouse_invariant_report(p_vendor_id) LOOP
    INSERT INTO public.warehouse_stocks (warehouse_id, product_id, quantity)
    VALUES (v_default, r.product_id, GREATEST(0, r.gap))
    ON CONFLICT (warehouse_id, product_id)
    DO UPDATE SET quantity = GREATEST(0, warehouse_stocks.quantity + r.gap), updated_at = now();
    INSERT INTO public.stock_movements (product_id, from_warehouse_id, to_warehouse_id, quantity, movement_type, notes, created_by)
    VALUES (
      r.product_id,
      CASE WHEN r.gap < 0 THEN v_default END,
      CASE WHEN r.gap > 0 THEN v_default END,
      abs(r.gap), CASE WHEN r.gap > 0 THEN 'in' ELSE 'out' END,
      'réconciliation invariant entrepôts', auth.uid()
    );
    v_fixed := v_fixed + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'fixed', v_fixed);
END $$;
REVOKE ALL ON FUNCTION public.reconcile_warehouse_stock(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reconcile_warehouse_stock(uuid) TO authenticated, service_role;
