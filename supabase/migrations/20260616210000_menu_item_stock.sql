-- ============================================================================
-- STOCK DES PLATS : nombre de portions disponibles par plat (existant) qui décrémente
-- à chaque vente (POS + commandes client) → « nombre restant ». NULL = illimité (non suivi).
-- Un plat à 0 devient indisponible. RPC atomique `consume_menu_stock` pour les ventes serveur.
-- ============================================================================

ALTER TABLE public.restaurant_menu_items
  ADD COLUMN IF NOT EXISTS stock_quantity integer;  -- NULL = illimité ; nombre = portions restantes

-- Décrémente le stock des plats vendus (atomique, FOR UPDATE). Ignore les plats non suivis (NULL).
-- Passe le plat en is_available=false quand il atteint 0. Lève STOCK_INSUFFISANT si pas assez.
CREATE OR REPLACE FUNCTION public.consume_menu_stock(p_items jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  it     jsonb;
  v_id   uuid;
  v_qty  int;
  v_stock int;
  v_name text;
BEGIN
  FOR it IN SELECT * FROM jsonb_array_elements(COALESCE(p_items, '[]'::jsonb)) LOOP
    v_id  := NULLIF(it->>'menu_item_id', '')::uuid;
    v_qty := GREATEST(1, COALESCE((it->>'quantity')::int, 1));
    IF v_id IS NULL THEN CONTINUE; END IF;

    SELECT stock_quantity, name INTO v_stock, v_name
    FROM public.restaurant_menu_items WHERE id = v_id FOR UPDATE;

    IF v_stock IS NULL THEN CONTINUE; END IF;        -- plat non suivi (illimité)
    IF v_stock < v_qty THEN
      RAISE EXCEPTION 'STOCK_INSUFFISANT:%', COALESCE(v_name, 'plat');
    END IF;

    UPDATE public.restaurant_menu_items
    SET stock_quantity = v_stock - v_qty,
        is_available   = CASE WHEN v_stock - v_qty <= 0 THEN false ELSE is_available END,
        updated_at     = now()
    WHERE id = v_id;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION public.consume_menu_stock(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.consume_menu_stock(jsonb) TO service_role;

SELECT 'Stock plats ajouté : restaurant_menu_items.stock_quantity + RPC consume_menu_stock.' AS status;
