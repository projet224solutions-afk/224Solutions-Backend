-- Corriger les subtotals des commandes pour qu'ils correspondent à SUM(order_items)
-- et recalculer total_amount = subtotal + tax - discount + shipping

WITH correct_totals AS (
  SELECT 
    oi.order_id,
    SUM(oi.quantity * oi.unit_price) AS correct_subtotal
  FROM public.order_items oi
  GROUP BY oi.order_id
)
UPDATE public.orders o
SET 
  subtotal = ct.correct_subtotal,
  total_amount = ct.correct_subtotal 
    + COALESCE(o.tax_amount, 0) 
    + COALESCE(o.shipping_amount, 0) 
    - COALESCE(o.discount_amount, 0),
  updated_at = NOW()
FROM correct_totals ct
WHERE o.id = ct.order_id
  AND ABS(COALESCE(o.subtotal, 0) - ct.correct_subtotal) > 0.01;

-- Marquer toutes les anomalies ORD_004 ouvertes comme résolues
UPDATE public.logic_anomalies
SET 
  resolved_at = NOW(),
  resolution_type = 'AUTO',
  status = 'corrected',
  corrected_at = NOW(),
  correction_type = 'auto',
  notes = COALESCE(notes || ' | ', '') || 'Auto-corrigé: subtotal recalculé depuis order_items'
WHERE rule_id = 'ORD_004'
  AND resolved_at IS NULL;