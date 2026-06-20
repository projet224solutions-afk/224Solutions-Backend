
-- 1. CORRIGER LA COMMANDE
UPDATE public.orders 
SET subtotal = 50000, total_amount = 50000
WHERE id = '78690d00-a77e-4f97-bd11-a78fc8a66913';

-- 2. MARQUER L'ANOMALIE COMME CORRIGÉE (status valide: corrected)
UPDATE public.logic_anomalies 
SET resolved_at = now(), 
    resolution_type = 'MANUAL',
    status = 'corrected',
    notes = COALESCE(notes, '') || ' | Corrigé: subtotal aligné sur items_total (50000). Commission de 2500 retirée du subtotal.'
WHERE id = '9a9f879e-4fda-435d-a40a-d41bf0fe283f';

-- 3. AJUSTER LE TRIGGER pour vérifier aussi items_total vs subtotal
CREATE OR REPLACE FUNCTION public.trigger_surveillance_order_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_items_total NUMERIC;
  v_expected_total NUMERIC;
  v_delta_total NUMERIC;
  v_delta_items NUMERIC;
  v_rule_id TEXT := 'ORD_004';
  v_now TIMESTAMPTZ := now();
BEGIN
  SELECT COALESCE(SUM(oi.quantity * oi.unit_price), 0)
    INTO v_items_total
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id;

  v_expected_total := NEW.subtotal
    + COALESCE(NEW.tax_amount, 0)
    + COALESCE(NEW.shipping_amount, 0)
    - COALESCE(NEW.discount_amount, 0);

  v_delta_total := COALESCE(NEW.total_amount, 0) - COALESCE(v_expected_total, 0);
  v_delta_items := COALESCE(NEW.subtotal, 0) - COALESCE(v_items_total, 0);

  IF ABS(v_delta_total) > 0.01 OR (v_items_total > 0 AND ABS(v_delta_items) > 0.01) THEN
    INSERT INTO public.logic_rules (
      rule_id, domain, name, description, expected_logic,
      detection_method, severity, auto_correctable, enabled, created_at, updated_at
    ) VALUES (
      v_rule_id, 'ORDERS', 'Cohérence total commande',
      'Vérifie total_amount = subtotal + tax + shipping - discount ET subtotal = SUM(items).',
      jsonb_build_object(
        'formula_total', 'subtotal + tax_amount + shipping_amount - discount_amount',
        'formula_subtotal', 'SUM(order_items.quantity * unit_price)',
        'tolerance', 0.01
      ),
      'TRIGGER', 'HIGH', true, true, v_now, v_now
    ) ON CONFLICT (rule_id) DO UPDATE
      SET updated_at = excluded.updated_at,
          description = excluded.description,
          expected_logic = excluded.expected_logic;

    IF NOT EXISTS (
      SELECT 1 FROM public.logic_anomalies la
      WHERE la.rule_id = v_rule_id
        AND la.entity_type = 'order'
        AND la.entity_id = NEW.id::text
        AND la.resolved_at IS NULL
        AND la.detected_at > (v_now - interval '1 hour')
    ) THEN
      INSERT INTO public.logic_anomalies (
        rule_id, domain, severity, expected_value, actual_value, difference,
        detected_at, entity_type, entity_id, action_type, status, detected_by, notes
      ) VALUES (
        v_rule_id, 'ORDERS', 'HIGH',
        jsonb_build_object(
          'expected_total', v_expected_total,
          'items_total', v_items_total,
          'subtotal', NEW.subtotal
        ),
        jsonb_build_object(
          'total_amount', NEW.total_amount,
          'status', NEW.status
        ),
        jsonb_build_object(
          'delta_total', v_delta_total,
          'delta_items_vs_subtotal', v_delta_items
        ),
        v_now, 'order', NEW.id::text, 'update', 'pending',
        'trigger_surveillance_order_total',
        format('Order %s: total=%s expected=%s delta_total=%s | subtotal=%s items=%s delta_items=%s',
          NEW.order_number, NEW.total_amount, v_expected_total, v_delta_total,
          NEW.subtotal, v_items_total, v_delta_items)
      );
    END IF;
  END IF;

  RETURN NEW;

EXCEPTION WHEN others THEN
  RAISE NOTICE '[trigger_surveillance_order_total] %', SQLERRM;
  RETURN NEW;
END;
$$;
