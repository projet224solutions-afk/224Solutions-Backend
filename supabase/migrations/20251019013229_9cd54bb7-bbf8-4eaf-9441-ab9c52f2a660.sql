-- ============================================
-- MODULE INVENTAIRE INTELLIGENT - 224SOLUTIONS
-- ============================================

-- Table des fournisseurs (suppliers)
CREATE TABLE IF NOT EXISTS public.suppliers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  name VARCHAR(255) NOT NULL,
  contact_person VARCHAR(255),
  email VARCHAR(255),
  phone VARCHAR(50),
  address TEXT,
  is_active BOOLEAN DEFAULT true,
  payment_terms INTEGER DEFAULT 30,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Table historique des mouvements de stock
CREATE TABLE IF NOT EXISTS public.inventory_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  movement_type VARCHAR(50) NOT NULL CHECK (movement_type IN ('sale', 'purchase', 'adjustment', 'return', 'transfer', 'loss')),
  quantity_change INTEGER NOT NULL,
  previous_quantity INTEGER NOT NULL,
  new_quantity INTEGER NOT NULL,
  order_id UUID REFERENCES public.orders(id),
  warehouse_id UUID REFERENCES public.warehouses(id),
  notes TEXT,
  user_id UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Table des alertes d'inventaire
CREATE TABLE IF NOT EXISTS public.inventory_alerts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  alert_type VARCHAR(50) NOT NULL CHECK (alert_type IN ('low_stock', 'out_of_stock', 'overstocked', 'expiring_soon', 'expired')),
  message TEXT NOT NULL,
  severity VARCHAR(20) DEFAULT 'medium' CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  is_read BOOLEAN DEFAULT false,
  is_resolved BOOLEAN DEFAULT false,
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Amélioration de la table inventory existante
ALTER TABLE public.inventory 
  ADD COLUMN IF NOT EXISTS sku VARCHAR(100) UNIQUE,
  ADD COLUMN IF NOT EXISTS barcode VARCHAR(100) UNIQUE,
  ADD COLUMN IF NOT EXISTS cost_price NUMERIC(10, 2) DEFAULT 0,
  ADD COLUMN IF NOT EXISTS supplier_id UUID REFERENCES public.suppliers(id),
  ADD COLUMN IF NOT EXISTS reorder_point INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS reorder_quantity INTEGER DEFAULT 0,
  ADD COLUMN IF NOT EXISTS location_details TEXT,
  ADD COLUMN IF NOT EXISTS notes TEXT;

-- Index pour optimiser les performances
CREATE INDEX IF NOT EXISTS idx_inventory_product ON public.inventory(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_warehouse ON public.inventory(warehouse_id);
CREATE INDEX IF NOT EXISTS idx_inventory_supplier ON public.inventory(supplier_id);
CREATE INDEX IF NOT EXISTS idx_inventory_history_product ON public.inventory_history(product_id);
CREATE INDEX IF NOT EXISTS idx_inventory_history_vendor ON public.inventory_history(vendor_id);
CREATE INDEX IF NOT EXISTS idx_inventory_history_created ON public.inventory_history(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_inventory_alerts_vendor ON public.inventory_alerts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_inventory_alerts_unread ON public.inventory_alerts(vendor_id, is_read) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_suppliers_vendor ON public.suppliers(vendor_id);

-- Fonction pour enregistrer automatiquement les mouvements de stock
CREATE OR REPLACE FUNCTION public.log_inventory_movement()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendor_id UUID;
  v_quantity_change INTEGER;
BEGIN
  -- Récupérer le vendor_id du produit
  SELECT p.vendor_id INTO v_vendor_id
  FROM products p
  WHERE p.id = NEW.product_id;

  -- Calculer le changement de quantité
  v_quantity_change := NEW.quantity - COALESCE(OLD.quantity, 0);

  -- Enregistrer le mouvement si la quantité a changé
  IF v_quantity_change != 0 THEN
    INSERT INTO inventory_history (
      product_id,
      vendor_id,
      movement_type,
      quantity_change,
      previous_quantity,
      new_quantity,
      warehouse_id,
      notes,
      user_id
    ) VALUES (
      NEW.product_id,
      v_vendor_id,
      CASE 
        WHEN v_quantity_change > 0 THEN 'adjustment'
        ELSE 'adjustment'
      END,
      v_quantity_change,
      COALESCE(OLD.quantity, 0),
      NEW.quantity,
      NEW.warehouse_id,
      'Stock adjustment',
      auth.uid()
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger pour enregistrer les mouvements
DROP TRIGGER IF EXISTS inventory_movement_trigger ON public.inventory;
CREATE TRIGGER inventory_movement_trigger
  AFTER INSERT OR UPDATE OF quantity ON public.inventory
  FOR EACH ROW
  EXECUTE FUNCTION public.log_inventory_movement();

-- Fonction pour mettre à jour le stock lors d'une vente
CREATE OR REPLACE FUNCTION public.update_inventory_on_sale()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item RECORD;
  v_vendor_id UUID;
BEGIN
  -- Seulement pour les commandes complétées ou en préparation
  IF NEW.status IN ('completed', 'processing') AND (OLD.status IS NULL OR OLD.status NOT IN ('completed', 'processing')) THEN
    
    -- Récupérer le vendor_id
    SELECT vendor_id INTO v_vendor_id FROM orders WHERE id = NEW.id;
    
    -- Mettre à jour le stock pour chaque item
    FOR v_item IN 
      SELECT oi.product_id, oi.quantity, oi.variant_id
      FROM order_items oi
      WHERE oi.order_id = NEW.id
    LOOP
      -- Mettre à jour l'inventaire principal
      UPDATE inventory
      SET quantity = GREATEST(0, quantity - v_item.quantity)
      WHERE product_id = v_item.product_id
        AND (variant_id = v_item.variant_id OR (variant_id IS NULL AND v_item.variant_id IS NULL));
      
      -- Enregistrer le mouvement
      INSERT INTO inventory_history (
        product_id,
        vendor_id,
        movement_type,
        quantity_change,
        previous_quantity,
        new_quantity,
        order_id,
        notes
      )
      SELECT 
        v_item.product_id,
        v_vendor_id,
        'sale',
        -v_item.quantity,
        i.quantity + v_item.quantity,
        i.quantity,
        NEW.id,
        'Sale order #' || NEW.order_number
      FROM inventory i
      WHERE i.product_id = v_item.product_id
        AND (i.variant_id = v_item.variant_id OR (i.variant_id IS NULL AND v_item.variant_id IS NULL));
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger pour mettre à jour le stock lors des ventes
DROP TRIGGER IF EXISTS update_inventory_on_order_completion ON public.orders;
CREATE TRIGGER update_inventory_on_order_completion
  AFTER UPDATE OF status ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.update_inventory_on_sale();

-- Fonction pour vérifier et créer des alertes automatiques
CREATE OR REPLACE FUNCTION public.check_inventory_alerts()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendor_id UUID;
  v_product_name TEXT;
  v_alert_exists BOOLEAN;
BEGIN
  -- Récupérer les informations du produit
  SELECT p.vendor_id, p.name INTO v_vendor_id, v_product_name
  FROM products p
  WHERE p.id = NEW.product_id;

  -- Alerte rupture de stock
  IF NEW.quantity = 0 THEN
    SELECT EXISTS(
      SELECT 1 FROM inventory_alerts 
      WHERE product_id = NEW.product_id 
        AND alert_type = 'out_of_stock' 
        AND is_resolved = false
    ) INTO v_alert_exists;

    IF NOT v_alert_exists THEN
      INSERT INTO inventory_alerts (
        vendor_id,
        product_id,
        alert_type,
        message,
        severity
      ) VALUES (
        v_vendor_id,
        NEW.product_id,
        'out_of_stock',
        'Le produit "' || v_product_name || '" est en rupture de stock',
        'critical'
      );
    END IF;
  
  -- Alerte stock faible
  ELSIF NEW.quantity <= NEW.minimum_stock AND NEW.quantity > 0 THEN
    SELECT EXISTS(
      SELECT 1 FROM inventory_alerts 
      WHERE product_id = NEW.product_id 
        AND alert_type = 'low_stock' 
        AND is_resolved = false
    ) INTO v_alert_exists;

    IF NOT v_alert_exists THEN
      INSERT INTO inventory_alerts (
        vendor_id,
        product_id,
        alert_type,
        message,
        severity
      ) VALUES (
        v_vendor_id,
        NEW.product_id,
        'low_stock',
        'Le produit "' || v_product_name || '" a un stock faible (' || NEW.quantity || ' unités)',
        'high'
      );
    END IF;
  
  -- Résoudre les alertes si le stock est rétabli
  ELSIF NEW.quantity > NEW.minimum_stock THEN
    UPDATE inventory_alerts
    SET is_resolved = true, resolved_at = now()
    WHERE product_id = NEW.product_id
      AND alert_type IN ('low_stock', 'out_of_stock')
      AND is_resolved = false;
  END IF;

  -- Alerte produit expirant bientôt (si date d'expiration dans moins de 30 jours)
  IF NEW.expiry_date IS NOT NULL 
     AND NEW.expiry_date <= (CURRENT_DATE + INTERVAL '30 days')
     AND NEW.expiry_date > CURRENT_DATE THEN
    
    SELECT EXISTS(
      SELECT 1 FROM inventory_alerts 
      WHERE product_id = NEW.product_id 
        AND alert_type = 'expiring_soon' 
        AND is_resolved = false
    ) INTO v_alert_exists;

    IF NOT v_alert_exists THEN
      INSERT INTO inventory_alerts (
        vendor_id,
        product_id,
        alert_type,
        message,
        severity
      ) VALUES (
        v_vendor_id,
        NEW.product_id,
        'expiring_soon',
        'Le produit "' || v_product_name || '" expire bientôt (le ' || NEW.expiry_date || ')',
        'medium'
      );
    END IF;
  END IF;

  -- Alerte produit expiré
  IF NEW.expiry_date IS NOT NULL AND NEW.expiry_date <= CURRENT_DATE THEN
    UPDATE inventory_alerts
    SET is_resolved = false, 
        alert_type = 'expired',
        message = 'Le produit "' || v_product_name || '" a expiré',
        severity = 'critical'
    WHERE product_id = NEW.product_id
      AND alert_type = 'expiring_soon';
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger pour vérifier les alertes
DROP TRIGGER IF EXISTS check_alerts_trigger ON public.inventory;
CREATE TRIGGER check_alerts_trigger
  AFTER INSERT OR UPDATE OF quantity, expiry_date ON public.inventory
  FOR EACH ROW
  EXECUTE FUNCTION public.check_inventory_alerts();

-- Fonction pour obtenir des statistiques d'inventaire
CREATE OR REPLACE FUNCTION public.get_inventory_stats(p_vendor_id UUID)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSON;
BEGIN
  SELECT json_build_object(
    'total_products', COUNT(DISTINCT i.product_id),
    'total_quantity', COALESCE(SUM(i.quantity), 0),
    'total_value', COALESCE(SUM(i.quantity * p.price), 0),
    'low_stock_count', COUNT(*) FILTER (WHERE i.quantity <= i.minimum_stock AND i.quantity > 0),
    'out_of_stock_count', COUNT(*) FILTER (WHERE i.quantity = 0),
    'total_cost', COALESCE(SUM(i.quantity * i.cost_price), 0),
    'potential_profit', COALESCE(SUM(i.quantity * (p.price - i.cost_price)), 0)
  ) INTO v_result
  FROM inventory i
  JOIN products p ON i.product_id = p.id
  WHERE p.vendor_id = p_vendor_id;

  RETURN v_result;
END;
$$;

-- RLS Policies
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_alerts ENABLE ROW LEVEL SECURITY;

-- Suppliers policies
CREATE POLICY "Vendors can manage their suppliers"
  ON public.suppliers FOR ALL
  USING (EXISTS (
    SELECT 1 FROM vendors v WHERE v.id = suppliers.vendor_id AND v.user_id = auth.uid()
  ));

-- Inventory history policies
CREATE POLICY "Vendors can view their inventory history"
  ON public.inventory_history FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM vendors v WHERE v.id = inventory_history.vendor_id AND v.user_id = auth.uid()
  ));

-- Inventory alerts policies
CREATE POLICY "Vendors can manage their inventory alerts"
  ON public.inventory_alerts FOR ALL
  USING (EXISTS (
    SELECT 1 FROM vendors v WHERE v.id = inventory_alerts.vendor_id AND v.user_id = auth.uid()
  ));

-- Service role policies (pour les edge functions)
CREATE POLICY "service_role_suppliers" ON public.suppliers FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_history" ON public.inventory_history FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_alerts" ON public.inventory_alerts FOR ALL USING (auth.role() = 'service_role');

-- Activer realtime pour les mises à jour en temps réel
ALTER PUBLICATION supabase_realtime ADD TABLE public.inventory;
ALTER PUBLICATION supabase_realtime ADD TABLE public.inventory_alerts;
ALTER PUBLICATION supabase_realtime ADD TABLE public.inventory_history;
ALTER PUBLICATION supabase_realtime ADD TABLE public.suppliers;