-- ============================================================================
-- RESTAURANT — RAPPORT DE CLÔTURE DE CAISSE (récap journalier).
-- Réservé propriétaire/agent actif. Renvoie : total encaissé, nombre de
-- commandes payées, répartition par mode de paiement, top 5 plats vendus.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.restaurant_daily_closeout(
  p_service_id uuid,
  p_date       date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner     uuid;
  v_uid       uuid := auth.uid();
  v_total     numeric := 0;
  v_count     int := 0;
  v_by_method jsonb;
  v_top_items jsonb;
BEGIN
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_service_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SERVICE_INTROUVABLE');
  END IF;

  -- Autorisation : propriétaire OU agent restaurant actif
  IF v_uid IS NULL OR v_uid <> v_owner THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.restaurant_agents
      WHERE professional_service_id = p_service_id AND user_id = v_uid AND is_active = true
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
    END IF;
  END IF;

  -- Totaux de la journée (commandes payées)
  SELECT COALESCE(sum(total), 0), count(*)
  INTO v_total, v_count
  FROM public.restaurant_orders
  WHERE professional_service_id = p_service_id
    AND payment_status = 'paid'
    AND created_at::date = p_date;

  -- Répartition par mode de paiement
  SELECT COALESCE(jsonb_object_agg(payment_method, method_total), '{}'::jsonb)
  INTO v_by_method
  FROM (
    SELECT COALESCE(payment_method, 'inconnu') AS payment_method, sum(total) AS method_total
    FROM public.restaurant_orders
    WHERE professional_service_id = p_service_id
      AND payment_status = 'paid'
      AND created_at::date = p_date
    GROUP BY COALESCE(payment_method, 'inconnu')
  ) m;

  -- Top 5 plats vendus (depuis le jsonb items)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', name, 'qty', qty) ORDER BY qty DESC), '[]'::jsonb)
  INTO v_top_items
  FROM (
    SELECT (i->>'name') AS name, sum(GREATEST(1, COALESCE((i->>'quantity')::int, 1))) AS qty
    FROM public.restaurant_orders o,
         jsonb_array_elements(o.items) i
    WHERE o.professional_service_id = p_service_id
      AND o.payment_status = 'paid'
      AND o.created_at::date = p_date
      AND (i->>'name') IS NOT NULL
    GROUP BY (i->>'name')
    ORDER BY qty DESC
    LIMIT 5
  ) t;

  RETURN jsonb_build_object(
    'success', true,
    'date', p_date,
    'total_revenue', v_total,
    'order_count', v_count,
    'by_payment_method', v_by_method,
    'top_items', v_top_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.restaurant_daily_closeout(uuid, date) FROM anon;
GRANT  EXECUTE ON FUNCTION public.restaurant_daily_closeout(uuid, date) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='restaurant_daily_closeout')
  THEN RAISE EXCEPTION 'RPC restaurant_daily_closeout absente'; END IF;
  RAISE NOTICE '✅ Migration restaurant_daily_closeout OK';
END; $$;

COMMIT;
