-- ============================================================================
-- FINALISATION COMMANDE CARTE (restaurant) — APRÈS confirmation Stripe.
--
-- Le chemin carte crée la commande 'pending' AVANT Stripe (pour l'order_id),
-- puis la confirme. handleStripeSuccess passait le statut PUIS décrémentait le
-- stock SÉPARÉMENT (void consumeStock, fire-and-forget) → si le stock échouait,
-- commande carte payée mais stock non décrémenté, erreur invisible. Ici : passage
-- en payée + décrément stock direct (FOR UPDATE) en UNE transaction. Idempotente :
-- si déjà payée, ne re-décrémente pas. Autorisation propriétaire OU agent actif.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.finalize_restaurant_card_order(
  p_order_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order    record;
  v_owner    uuid;
  v_uid      uuid := auth.uid();
  it         jsonb;
  v_mid      uuid;
  v_qty      int;
  v_stock    int;
BEGIN
  -- Verrou : évite une double finalisation concurrente.
  SELECT * INTO v_order FROM public.restaurant_orders
    WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'COMMANDE_INTROUVABLE');
  END IF;

  -- Autorisation : propriétaire OU agent actif du service
  SELECT user_id INTO v_owner FROM public.professional_services
    WHERE id = v_order.professional_service_id;
  IF v_uid IS NULL OR (v_uid <> v_owner AND NOT EXISTS (
    SELECT 1 FROM public.restaurant_agents
    WHERE professional_service_id = v_order.professional_service_id
      AND user_id = v_uid AND is_active = true
  )) THEN
    RETURN jsonb_build_object('success', false, 'error', 'NON_AUTORISE');
  END IF;

  -- ✅ Idempotence : déjà payée → succès sans re-décrémenter le stock
  IF v_order.payment_status = 'paid' THEN
    RETURN jsonb_build_object('success', true, 'already_finalized', true);
  END IF;

  -- Passer la commande en payée/complétée
  UPDATE public.restaurant_orders
  SET payment_status = 'paid', status = 'completed', completed_at = now()
  WHERE id = p_order_id;

  -- ✅ Décrément stock ATOMIQUE (stock - qty direct, FOR UPDATE), même transaction
  FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(v_order.items, '[]'::jsonb)) LOOP
    v_mid := NULLIF(it->>'menu_item_id', '')::uuid;
    v_qty := GREATEST(1, COALESCE((it->>'quantity')::int, 1));
    IF v_mid IS NULL THEN CONTINUE; END IF;

    SELECT stock_quantity INTO v_stock FROM public.restaurant_menu_items
      WHERE id = v_mid AND professional_service_id = v_order.professional_service_id
      FOR UPDATE;
    IF v_stock IS NULL THEN CONTINUE; END IF;  -- stock illimité ou plat absent

    UPDATE public.restaurant_menu_items
    SET stock_quantity = GREATEST(0, stock_quantity - v_qty),
        is_available   = CASE WHEN stock_quantity - v_qty <= 0 THEN false ELSE is_available END,
        updated_at     = now()
    WHERE id = v_mid;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'order_id', p_order_id);

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

REVOKE ALL ON FUNCTION public.finalize_restaurant_card_order(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.finalize_restaurant_card_order(uuid) TO authenticated, service_role;

DO $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_proc WHERE proname='finalize_restaurant_card_order')
  THEN RAISE EXCEPTION 'RPC finalize_restaurant_card_order absente'; END IF;
  RAISE NOTICE '✅ Migration restaurant_card_finalize OK';
END; $$;

COMMIT;
