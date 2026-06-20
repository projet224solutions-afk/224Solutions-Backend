-- =============================================================================
-- FIX COMPLET: trigger_surveillance_order_total ne doit JAMAIS bloquer un UPDATE
-- - Corrige les colonnes inexistantes (is_active, context, is_resolved)
-- - Aligne le calcul avec le modèle: total_amount = subtotal + taxes + shipping - discount
-- - Crée/assure la règle ORD_004 avec les champs requis de logic_rules
-- - Log une anomalie uniquement si incohérence réelle du total
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trigger_surveillance_order_total()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_items_total NUMERIC;
  v_expected_total NUMERIC;
  v_delta NUMERIC;
  v_rule_id TEXT := 'ORD_004';
  v_now TIMESTAMPTZ := now();
BEGIN
  -- Total des items (info utile pour diagnostic, mais pas forcément égal au subtotal)
  SELECT COALESCE(SUM(oi.quantity * oi.unit_price), 0)
    INTO v_items_total
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id;

  -- Total attendu selon la structure de la commande
  v_expected_total := NEW.subtotal
    + COALESCE(NEW.tax_amount, 0)
    + COALESCE(NEW.shipping_amount, 0)
    - COALESCE(NEW.discount_amount, 0);

  v_delta := COALESCE(NEW.total_amount, 0) - COALESCE(v_expected_total, 0);

  -- Si incohérence réelle, on log une anomalie (sans casser le process)
  IF ABS(v_delta) > 0.01 THEN
    -- S'assurer que la règle existe (logic_anomalies.rule_id a un FK vers logic_rules.rule_id)
    INSERT INTO public.logic_rules (
      rule_id,
      domain,
      name,
      description,
      expected_logic,
      detection_method,
      severity,
      auto_correctable,
      enabled,
      created_at,
      updated_at
    )
    VALUES (
      v_rule_id,
      'ORDERS',
      'Cohérence total commande',
      'Vérifie que total_amount = subtotal + tax_amount + shipping_amount - discount_amount (tolérance 0.01).',
      jsonb_build_object(
        'formula', 'subtotal + tax_amount + shipping_amount - discount_amount',
        'tolerance', 0.01
      ),
      'TRIGGER',
      'HIGH',
      true,
      true,
      v_now,
      v_now
    )
    ON CONFLICT (rule_id) DO UPDATE
      SET updated_at = excluded.updated_at;

    -- Éviter le spam: ne pas recréer la même anomalie si déjà ouverte pour cette commande
    IF NOT EXISTS (
      SELECT 1
      FROM public.logic_anomalies la
      WHERE la.rule_id = v_rule_id
        AND la.entity_type = 'order'
        AND la.entity_id = NEW.id::text
        AND la.resolved_at IS NULL
        AND la.detected_at > (v_now - interval '1 hour')
    ) THEN
      INSERT INTO public.logic_anomalies (
        rule_id,
        domain,
        severity,
        expected_value,
        actual_value,
        difference,
        detected_at,
        entity_type,
        entity_id,
        action_type,
        status,
        detected_by,
        notes
      )
      VALUES (
        v_rule_id,
        'ORDERS',
        'HIGH',
        jsonb_build_object(
          'expected_total', v_expected_total,
          'subtotal', NEW.subtotal,
          'tax_amount', COALESCE(NEW.tax_amount, 0),
          'shipping_amount', COALESCE(NEW.shipping_amount, 0),
          'discount_amount', COALESCE(NEW.discount_amount, 0)
        ),
        jsonb_build_object(
          'total_amount', NEW.total_amount,
          'status', NEW.status,
          'payment_status', NEW.payment_status
        ),
        jsonb_build_object(
          'delta', v_delta,
          'items_total', v_items_total
        ),
        v_now,
        'order',
        NEW.id::text,
        'update',
        'pending',
        'trigger_surveillance_order_total',
        format(
          'Order %s (vendor %s): total_amount=%s expected=%s delta=%s',
          NEW.order_number,
          NEW.vendor_id,
          NEW.total_amount,
          v_expected_total,
          v_delta
        )
      );
    END IF;
  END IF;

  RETURN NEW;

EXCEPTION WHEN others THEN
  -- IMPORTANT: ne jamais bloquer le workflow vendeur à cause du monitoring
  RAISE NOTICE '[trigger_surveillance_order_total] %', SQLERRM;
  RETURN NEW;
END;
$$;