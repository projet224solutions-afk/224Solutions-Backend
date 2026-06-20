-- 🔁 RPC ATOMIQUE — validation d'un achat de stock (remplace l'edge validate-purchase).
-- Tout en UNE transaction (le RPC) : dépense verrouillée + maj stock/cost/price des produits
-- + marquage fournisseurs + verrouillage de l'achat. Idempotent (achat déjà validé → no-op).
-- Appelé par le backend Node (/api/inventory/validate-purchase) avec vérif de propriété.

CREATE OR REPLACE FUNCTION public.validate_stock_purchase(
  p_purchase_id uuid,
  p_vendor_id uuid,
  p_items jsonb,
  p_purchase_number text,
  p_total_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id uuid;
  v_expense_id uuid;
  v_item jsonb;
  v_supplier_ids uuid[];
  v_supplier_names text;
  v_desc text;
  v_purchase record;
BEGIN
  IF p_purchase_id IS NULL OR p_vendor_id IS NULL OR p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Paramètres manquants');
  END IF;

  -- user_id du vendeur (vendor_expenses.vendor_id référence auth.users)
  SELECT user_id INTO v_user_id FROM public.vendors WHERE id = p_vendor_id;
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Vendor non trouvé ou user_id manquant');
  END IF;

  -- verrou + idempotence : l'achat doit appartenir au vendeur et ne pas être déjà validé
  SELECT id, status, is_locked, expense_id INTO v_purchase
  FROM public.stock_purchases
  WHERE id = p_purchase_id AND vendor_id = p_vendor_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Achat introuvable pour ce vendeur');
  END IF;
  IF v_purchase.status = 'validated' OR COALESCE(v_purchase.is_locked, false) = true THEN
    RETURN jsonb_build_object('success', true, 'already_validated', true, 'expense_id', v_purchase.expense_id, 'message', 'Achat déjà validé');
  END IF;

  -- fournisseurs uniques
  SELECT array_agg(DISTINCT (e->>'supplier_id')::uuid)
  INTO v_supplier_ids
  FROM jsonb_array_elements(p_items) e
  WHERE NULLIF(e->>'supplier_id', '') IS NOT NULL;

  v_desc := 'Achat de stock - ' || p_purchase_number;
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    SELECT string_agg(name, ', ') INTO v_supplier_names
    FROM public.vendor_suppliers WHERE id = ANY(v_supplier_ids);
    IF v_supplier_names IS NOT NULL THEN
      v_desc := v_desc || ' - Fournisseur(s): ' || v_supplier_names;
    END IF;
  END IF;

  -- 1) dépense verrouillée
  INSERT INTO public.vendor_expenses (vendor_id, description, amount, expense_date, payment_method, status, is_locked, purchase_reference)
  VALUES (v_user_id, v_desc, p_total_amount, CURRENT_DATE, 'cash', 'paid', true, p_purchase_number)
  RETURNING id INTO v_expense_id;

  -- 2) stock + cost_price + price par produit (scopé au vendeur)
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    IF NULLIF(v_item->>'product_id', '') IS NOT NULL THEN
      UPDATE public.products SET
        stock_quantity = COALESCE(stock_quantity, 0) + COALESCE((v_item->>'quantity')::numeric, 0),
        cost_price = NULLIF(v_item->>'purchase_price', '')::numeric,
        price = COALESCE(NULLIF(v_item->>'selling_price', '')::numeric, price)
      WHERE id = (v_item->>'product_id')::uuid AND vendor_id = p_vendor_id;
    END IF;
  END LOOP;

  -- 3) fournisseurs marqués validés (scopé)
  IF v_supplier_ids IS NOT NULL AND array_length(v_supplier_ids, 1) > 0 THEN
    UPDATE public.vendor_suppliers SET has_validated_purchases = true
    WHERE id = ANY(v_supplier_ids) AND vendor_id = p_vendor_id;
  END IF;

  -- 4) valider + verrouiller l'achat
  UPDATE public.stock_purchases
  SET status = 'validated', validated_at = NOW(), expense_id = v_expense_id, is_locked = true
  WHERE id = p_purchase_id;

  RETURN jsonb_build_object('success', true, 'expense_id', v_expense_id, 'message', 'Achat ' || p_purchase_number || ' validé. Stock, prix d''achat et dépenses mis à jour.');
END;
$$;

REVOKE ALL ON FUNCTION public.validate_stock_purchase(uuid, uuid, jsonb, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.validate_stock_purchase(uuid, uuid, jsonb, text, numeric) TO service_role;
