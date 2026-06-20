-- 1) Nettoyer les doublons d'anomalies ouvertes (même règle / même entité / même action)
WITH ranked_open AS (
  SELECT
    id,
    ROW_NUMBER() OVER (
      PARTITION BY rule_id, domain, entity_type, entity_id, action_type
      ORDER BY detected_at DESC, created_at DESC, id DESC
    ) AS rn
  FROM public.logic_anomalies
  WHERE resolved_at IS NULL
)
UPDATE public.logic_anomalies la
SET
  resolved_at = NOW(),
  resolution_type = COALESCE(la.resolution_type, 'AUTO'),
  status = 'corrected',
  notes = CASE
    WHEN COALESCE(la.notes, '') = '' THEN 'Auto-résolu: doublon technique supprimé'
    ELSE la.notes || ' | Auto-résolu: doublon technique supprimé'
  END
FROM ranked_open ro
WHERE la.id = ro.id
  AND ro.rn > 1;

-- 2) Empêcher la recréation de doublons ouverts
CREATE UNIQUE INDEX IF NOT EXISTS uq_logic_anomalies_open_key
ON public.logic_anomalies (rule_id, domain, entity_type, entity_id, action_type)
NULLS NOT DISTINCT
WHERE resolved_at IS NULL;

-- 3) Trigger ORD_004 robuste: mise à jour d'une anomalie ouverte existante au lieu d'insérer en boucle
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
  v_now TIMESTAMPTZ := NOW();
  v_note TEXT;
BEGIN
  SELECT COALESCE(SUM(oi.quantity * oi.unit_price), 0)
    INTO v_items_total
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id;

  v_expected_total := COALESCE(NEW.subtotal, 0)
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
      v_rule_id,
      'ORDERS',
      'Cohérence total commande',
      'Vérifie total_amount = subtotal + tax + shipping - discount ET subtotal = SUM(items).',
      jsonb_build_object(
        'formula_total', 'subtotal + tax_amount + shipping_amount - discount_amount',
        'formula_subtotal', 'SUM(order_items.quantity * unit_price)',
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
      SET
        updated_at = EXCLUDED.updated_at,
        description = EXCLUDED.description,
        expected_logic = EXCLUDED.expected_logic,
        severity = EXCLUDED.severity,
        enabled = true;

    v_note := format(
      'Order %s: total=%s expected=%s delta_total=%s | subtotal=%s items=%s delta_items=%s',
      NEW.order_number,
      NEW.total_amount,
      v_expected_total,
      v_delta_total,
      NEW.subtotal,
      v_items_total,
      v_delta_items
    );

    BEGIN
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
      ) VALUES (
        v_rule_id,
        'ORDERS',
        'HIGH',
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
        v_now,
        'order',
        NEW.id::text,
        'update',
        'pending',
        'trigger_surveillance_order_total',
        v_note
      );
    EXCEPTION WHEN unique_violation THEN
      UPDATE public.logic_anomalies la
      SET
        detected_at = v_now,
        severity = 'HIGH',
        expected_value = jsonb_build_object(
          'expected_total', v_expected_total,
          'items_total', v_items_total,
          'subtotal', NEW.subtotal
        ),
        actual_value = jsonb_build_object(
          'total_amount', NEW.total_amount,
          'status', NEW.status
        ),
        difference = jsonb_build_object(
          'delta_total', v_delta_total,
          'delta_items_vs_subtotal', v_delta_items
        ),
        status = 'pending',
        notes = v_note
      WHERE la.rule_id = v_rule_id
        AND la.domain = 'ORDERS'
        AND la.entity_type = 'order'
        AND la.entity_id = NEW.id::text
        AND la.action_type = 'update'
        AND la.resolved_at IS NULL;
    END;
  END IF;

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE '[trigger_surveillance_order_total] %', SQLERRM;
  RETURN NEW;
END;
$$;