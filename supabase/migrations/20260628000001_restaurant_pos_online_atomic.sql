-- ============================================================================
-- CAISSE RESTAURANT EN LIGNE — encaissement ATOMIQUE (commande + stock).
--
-- Sœur de create_restaurant_pos_offline_order (qu'on NE touche PAS). Le POS en
-- ligne (espèces/mobile) insérait la commande PUIS décrémentait le stock
-- SÉPARÉMENT (void consumeStock, fire-and-forget) → si le stock échouait, vente
-- encaissée mais stock non décrémenté, erreur invisible. Ici tout est dans UNE
-- transaction : insert commande + décrément stock direct (stock - qty, FOR UPDATE).
-- Autorisation : propriétaire du service OU agent restaurant actif.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.create_restaurant_pos_order_atomic(
  p_service_id uuid,
  p_order      jsonb            -- { order_type, status, customer_name, table_number,
                                --   payment_method, payment_status, subtotal, tax,
                                --   discount_amount, total, notes, items[] }
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner    uuid;
  v_uid      uuid := auth.uid();
  v_is_agent boolean := false;
  v_order_id uuid;
  v_items    jsonb := COALESCE(p_order->'items', '[]'::jsonb);
  it         jsonb;
  v_mid      uuid;
  v_qty      int;
  v_stock    int;
BEGIN
  -- ── Validation ──
  IF p_service_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SERVICE_REQUIS');
  END IF;
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTHENTIFIE');
  END IF;

  -- ── Autorisation : propriétaire OU agent restaurant actif ──
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_service_id;
  IF v_owner IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'SERVICE_INTROUVABLE');
  END IF;

  IF v_uid <> v_owner THEN
    BEGIN
      SELECT true INTO v_is_agent
      FROM public.restaurant_agents
      WHERE professional_service_id = p_service_id
        AND user_id = v_uid
        AND is_active = true
      LIMIT 1;
    EXCEPTION WHEN undefined_table THEN v_is_agent := false;
    END;

    IF NOT COALESCE(v_is_agent, false) THEN
      RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
    END IF;
  END IF;

  -- ── Insert commande ──
  INSERT INTO public.restaurant_orders (
    professional_service_id, source, order_type, status,
    customer_name, table_number, payment_method, payment_status,
    subtotal, tax, discount_amount, total, notes, items, completed_at, created_at
  )
  VALUES (
    p_service_id,
    'pos',
    COALESCE(p_order->>'order_type', 'dine_in'),
    COALESCE(p_order->>'status', 'completed'),
    COALESCE(NULLIF(p_order->>'customer_name', ''), 'Client'),
    NULLIF(p_order->>'table_number', ''),
    COALESCE(p_order->>'payment_method', 'cash'),
    COALESCE(p_order->>'payment_status', 'paid'),
    GREATEST(0, COALESCE((p_order->>'subtotal')::numeric, 0)),
    GREATEST(0, COALESCE((p_order->>'tax')::numeric, 0)),
    GREATEST(0, COALESCE((p_order->>'discount_amount')::numeric, 0)),
    GREATEST(0, COALESCE((p_order->>'total')::numeric, 0)),
    NULLIF(p_order->>'notes', ''),
    v_items,
    CASE WHEN COALESCE(p_order->>'payment_status','paid') = 'paid' THEN now() ELSE NULL END,
    now()
  )
  RETURNING id INTO v_order_id;

  -- ── Décrément stock ATOMIQUE (stock - qty direct, pas de read-then-write applicatif) ──
  -- Plats à stock suivi (stock_quantity NOT NULL). Stock NULL = illimité.
  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_mid := NULLIF(it->>'menu_item_id', '')::uuid;
    v_qty := GREATEST(1, COALESCE((it->>'quantity')::int, 1));
    IF v_mid IS NULL THEN CONTINUE; END IF;

    -- Verrou ligne (sérialise les ventes concurrentes du même plat)
    SELECT stock_quantity INTO v_stock
    FROM public.restaurant_menu_items
    WHERE id = v_mid AND professional_service_id = p_service_id
    FOR UPDATE;

    -- Plat illimité (NULL) ou introuvable → pas de limite
    IF v_stock IS NULL THEN CONTINUE; END IF;

    UPDATE public.restaurant_menu_items
    SET stock_quantity = GREATEST(0, stock_quantity - v_qty),
        is_available   = CASE WHEN stock_quantity - v_qty <= 0 THEN false ELSE is_available END,
        updated_at     = now()
    WHERE id = v_mid;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'order_id', v_order_id);

EXCEPTION WHEN OTHERS THEN
  -- Toute erreur → ROLLBACK de TOUTES les écritures ci-dessus (commande + stock).
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.create_restaurant_pos_order_atomic(uuid, jsonb) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.create_restaurant_pos_order_atomic(uuid, jsonb) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='create_restaurant_pos_order_atomic')
  THEN RAISE EXCEPTION 'RPC create_restaurant_pos_order_atomic absente'; END IF;
  RAISE NOTICE '✅ Migration restaurant_pos_online_atomic OK';
END; $$;

COMMIT;
