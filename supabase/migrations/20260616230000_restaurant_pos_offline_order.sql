-- ============================================================================
-- CAISSE RESTAURANT HORS LIGNE — synchronisation ATOMIQUE & IDEMPOTENTE.
--
-- La caisse de comptoir du restaurateur (RestaurantPOS) doit pouvoir encaisser
-- SANS internet : la vente est stockée localement (IndexedDB) puis rejouée à la
-- reconnexion. Comme le POS comptoir est réglé EN PERSONNE (espèces/MoMo/carte,
-- aucun mouvement wallet), l'écriture va directement dans restaurant_orders —
-- mais on la rend tout-ou-rien + anti-doublon, exactement comme le POS vendeur.
--
-- Idempotence : un identifiant de vente STABLE est généré hors ligne (order_number
-- « RESTO-OFF-… ») ; un index unique partiel garantit qu'un rejeu N'INSÈRE PAS deux
-- fois. La RPC renvoie alors 'duplicate' = succès (pas de double encaissement).
-- ============================================================================

-- 1) Anti-doublon : une seule commande POS hors ligne par (service, order_number).
--    Scopé à source='pos_offline' → AUCUN impact sur les autres flux (client, pay-mobile).
CREATE UNIQUE INDEX IF NOT EXISTS uniq_restaurant_orders_pos_offline
  ON public.restaurant_orders (professional_service_id, order_number)
  WHERE source = 'pos_offline' AND order_number IS NOT NULL;

-- 2) RPC atomique : insère la commande POS + décrémente le stock des plats, en UNE
--    transaction, idempotente, autorisée (le caller DOIT être le propriétaire du service).
CREATE OR REPLACE FUNCTION public.create_restaurant_pos_offline_order(
  p_service_id   uuid,
  p_order_number text,
  p_order        jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner    uuid;
  v_order_id uuid;
  v_items    jsonb := COALESCE(p_order->'items', '[]'::jsonb);
  it         jsonb;
  v_mid      uuid;
  v_qty      int;
BEGIN
  IF p_service_id IS NULL OR p_order_number IS NULL OR length(trim(p_order_number)) = 0 THEN
    RAISE EXCEPTION 'PARAMS_INVALIDES';
  END IF;

  -- Autorisation : seul le propriétaire du service peut encaisser sur sa caisse.
  SELECT user_id INTO v_owner FROM public.professional_services WHERE id = p_service_id;
  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'SERVICE_INTROUVABLE';
  END IF;
  IF auth.uid() IS NULL OR auth.uid() <> v_owner THEN
    RAISE EXCEPTION 'NON_AUTORISE';
  END IF;

  -- Insertion idempotente : si la vente a déjà été rejouée, on ne réinsère pas.
  INSERT INTO public.restaurant_orders (
    professional_service_id, order_number, source, order_type, status,
    customer_name, table_number, payment_method, payment_status,
    subtotal, tax, discount_amount, total, notes, items, created_at
  )
  VALUES (
    p_service_id,
    p_order_number,
    'pos_offline',
    COALESCE(p_order->>'order_type', 'dine_in'),
    COALESCE(p_order->>'status', 'completed'),
    NULLIF(p_order->>'customer_name', ''),
    NULLIF(p_order->>'table_number', ''),
    COALESCE(p_order->>'payment_method', 'cash'),
    COALESCE(p_order->>'payment_status', 'paid'),
    GREATEST(0, COALESCE((p_order->>'subtotal')::numeric, 0)),
    GREATEST(0, COALESCE((p_order->>'tax')::numeric, 0)),
    GREATEST(0, COALESCE((p_order->>'discount_amount')::numeric, 0)),
    GREATEST(0, COALESCE((p_order->>'total')::numeric, 0)),
    NULLIF(p_order->>'notes', ''),
    v_items,
    COALESCE((p_order->>'created_at')::timestamptz, now())
  )
  ON CONFLICT (professional_service_id, order_number)
    WHERE source = 'pos_offline' AND order_number IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_order_id;

  -- Déjà présente (rejeu) → succès idempotent, sans re-décrémenter le stock.
  IF v_order_id IS NULL THEN
    SELECT id INTO v_order_id
    FROM public.restaurant_orders
    WHERE professional_service_id = p_service_id
      AND order_number = p_order_number
      AND source = 'pos_offline'
    LIMIT 1;
    RETURN jsonb_build_object('status', 'duplicate', 'order_id', v_order_id);
  END IF;

  -- Première insertion → décrément stock BEST-EFFORT (même transaction, atomique).
  -- ⚠️ Vente comptoir DÉJÀ encaissée en personne : on n'ÉCHOUE JAMAIS sur un stock
  -- insuffisant (sinon perte d'argent). On clampe à 0 ; plats à stock NULL = illimité ignorés.
  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_mid := NULLIF(it->>'menu_item_id', '')::uuid;
    v_qty := GREATEST(1, COALESCE((it->>'quantity')::int, 1));
    IF v_mid IS NULL THEN CONTINUE; END IF;
    UPDATE public.restaurant_menu_items
    SET stock_quantity = GREATEST(0, stock_quantity - v_qty),
        is_available   = CASE WHEN stock_quantity - v_qty <= 0 THEN false ELSE is_available END,
        updated_at     = now()
    WHERE id = v_mid AND stock_quantity IS NOT NULL;
  END LOOP;

  RETURN jsonb_build_object('status', 'created', 'order_id', v_order_id);
END;
$$;

REVOKE ALL ON FUNCTION public.create_restaurant_pos_offline_order(uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_restaurant_pos_offline_order(uuid, text, jsonb) TO authenticated, service_role;

SELECT 'Caisse restaurant hors ligne : index anti-doublon + RPC atomique create_restaurant_pos_offline_order.' AS status;
