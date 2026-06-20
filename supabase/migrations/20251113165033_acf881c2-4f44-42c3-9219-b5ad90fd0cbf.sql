-- ============================================
-- CORRECTION: Vérification du stock lors de la création de commande
-- ============================================

-- Recréer la fonction create_online_order avec vérification de stock
CREATE OR REPLACE FUNCTION public.create_online_order(
  p_user_id UUID,
  p_vendor_id UUID,
  p_items JSONB,
  p_total_amount NUMERIC,
  p_payment_method TEXT DEFAULT 'wallet',
  p_shipping_address JSONB DEFAULT NULL
)
RETURNS TABLE(order_id UUID, order_number TEXT, customer_id UUID)
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_customer_id UUID;
  v_order_id UUID;
  v_order_number TEXT;
  v_item JSONB;
  v_payment_method payment_method;
  v_payment_status payment_status;
  v_product_id UUID;
  v_requested_quantity INTEGER;
  v_current_stock INTEGER;
  v_product_name TEXT;
BEGIN
  -- Récupérer ou créer le customer_id
  SELECT id INTO v_customer_id
  FROM public.customers
  WHERE user_id = p_user_id;
  
  IF v_customer_id IS NULL THEN
    INSERT INTO public.customers (user_id, created_at, updated_at)
    VALUES (p_user_id, NOW(), NOW())
    RETURNING id INTO v_customer_id;
  END IF;
  
  -- VÉRIFIER LE STOCK POUR CHAQUE PRODUIT
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::UUID;
    v_requested_quantity := (v_item->>'quantity')::INTEGER;
    
    -- Récupérer le stock actuel et le nom du produit
    SELECT stock_quantity, name
    INTO v_current_stock, v_product_name
    FROM public.products
    WHERE id = v_product_id AND is_active = true;
    
    -- Vérifier si le produit existe
    IF v_product_name IS NULL THEN
      RAISE EXCEPTION 'Le produit % n''existe pas ou n''est pas actif', v_product_id;
    END IF;
    
    -- Vérifier si le stock est suffisant
    IF v_current_stock < v_requested_quantity THEN
      RAISE EXCEPTION 'Stock insuffisant pour "%". Stock disponible: %, Quantité demandée: %', 
        v_product_name, v_current_stock, v_requested_quantity;
    END IF;
  END LOOP;
  
  -- Générer un numéro de commande unique
  v_order_number := 'ORD' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
  
  -- Mapper le payment_method vers l'enum
  v_payment_method := CASE 
    WHEN p_payment_method IN ('wallet', 'mobile_money', 'card', 'cash', 'bank_transfer') 
    THEN p_payment_method::payment_method
    ELSE 'wallet'::payment_method
  END;
  
  -- Déterminer le payment_status
  v_payment_status := CASE 
    WHEN p_payment_method = 'cash' THEN 'pending'::payment_status
    ELSE 'paid'::payment_status
  END;
  
  -- Créer la commande
  INSERT INTO public.orders (
    customer_id,
    vendor_id,
    order_number,
    total_amount,
    subtotal,
    status,
    payment_status,
    payment_method,
    shipping_address,
    source,
    created_at,
    updated_at
  ) VALUES (
    v_customer_id,
    p_vendor_id,
    v_order_number,
    p_total_amount,
    p_total_amount,
    'pending'::order_status,
    v_payment_status,
    v_payment_method,
    COALESCE(p_shipping_address, '{"address": "Conakry"}'::JSONB),
    'online',
    NOW(),
    NOW()
  )
  RETURNING id INTO v_order_id;
  
  -- Créer les items et DÉCRÉMENTER LE STOCK
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_product_id := (v_item->>'product_id')::UUID;
    v_requested_quantity := (v_item->>'quantity')::INTEGER;
    
    -- Créer l'item de commande
    INSERT INTO public.order_items (
      order_id,
      product_id,
      quantity,
      unit_price,
      total_price
    ) VALUES (
      v_order_id,
      v_product_id,
      v_requested_quantity,
      (v_item->>'price')::NUMERIC,
      v_requested_quantity * (v_item->>'price')::NUMERIC
    );
    
    -- Décrémenter le stock
    UPDATE public.products
    SET stock_quantity = stock_quantity - v_requested_quantity,
        updated_at = NOW()
    WHERE id = v_product_id;
  END LOOP;
  
  RETURN QUERY SELECT v_order_id, v_order_number, v_customer_id;
END;
$$;

COMMENT ON FUNCTION public.create_online_order IS 'Crée une commande en ligne avec vérification du stock et décrémentation automatique';