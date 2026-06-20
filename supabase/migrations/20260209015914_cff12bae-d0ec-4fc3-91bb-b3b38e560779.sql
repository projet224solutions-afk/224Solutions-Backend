-- =============================================================================
-- FIX: Corriger le trigger - La colonne rule_type n'existe pas dans logic_rules
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trigger_surveillance_order_total()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_calculated_total NUMERIC;
  v_rule_id TEXT := 'ORD_004';
BEGIN
  -- Calculer le total attendu depuis order_items
  SELECT COALESCE(SUM(quantity * unit_price), 0)
  INTO v_calculated_total
  FROM order_items
  WHERE order_id = NEW.id;

  -- Si le total stocké ne correspond pas au total calculé, logger une anomalie
  IF NEW.total_amount IS NOT NULL AND ABS(NEW.total_amount - v_calculated_total) > 0.01 THEN
    -- Vérifier si la règle existe, sinon la créer (sans rule_type qui n'existe pas)
    INSERT INTO public.logic_rules (rule_id, name, domain, severity, is_active)
    VALUES (v_rule_id, 'Vérification total commande', 'ORDERS', 'HIGH', true)
    ON CONFLICT (rule_id) DO NOTHING;

    -- Insérer l'anomalie avec le rule_id requis
    INSERT INTO public.logic_anomalies (
      rule_id,
      domain,
      severity,
      expected_value,
      actual_value,
      detected_at,
      is_resolved,
      context
    )
    VALUES (
      v_rule_id,
      'ORDERS',
      'HIGH',
      v_calculated_total::TEXT,
      NEW.total_amount::TEXT,
      NOW(),
      false,
      jsonb_build_object(
        'order_id', NEW.id,
        'vendor_id', NEW.vendor_id,
        'difference', ABS(NEW.total_amount - v_calculated_total)
      )
    );
  END IF;

  RETURN NEW;
END;
$$;