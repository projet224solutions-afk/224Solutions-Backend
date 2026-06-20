-- ============================================
-- CORRECTION SYSTÈME DE COMMANDES - PARTIE 1
-- Créer les fonctions d'abord
-- ============================================

-- 1. Fonction pour créer automatiquement un customer
CREATE OR REPLACE FUNCTION public.create_customer_on_signup()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.customers (user_id, created_at, updated_at)
  VALUES (NEW.id, NOW(), NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- 2. Fonction pour créer une commande en ligne
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
  
  -- Générer un numéro de commande unique
  v_order_number := 'ORD' || TO_CHAR(NOW(), 'YYYYMMDD') || '-' || LPAD(FLOOR(RANDOM() * 10000)::TEXT, 4, '0');
  
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
    'pending',
    CASE WHEN p_payment_method = 'cash' THEN 'pending' ELSE 'paid' END,
    p_payment_method::payment_method,
    COALESCE(p_shipping_address, '{"address": "Conakry"}'::JSONB),
    'online',
    NOW(),
    NOW()
  )
  RETURNING id INTO v_order_id;
  
  -- Créer les items
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.order_items (
      order_id,
      product_id,
      quantity,
      unit_price,
      total_price
    ) VALUES (
      v_order_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity')::INTEGER,
      (v_item->>'price')::NUMERIC,
      (v_item->>'quantity')::INTEGER * (v_item->>'price')::NUMERIC
    );
  END LOOP;
  
  RETURN QUERY SELECT v_order_id, v_order_number, v_customer_id;
END;
$$;

-- 3. S'assurer que tous les profils ont un customer
INSERT INTO public.customers (user_id, created_at, updated_at)
SELECT p.id, NOW(), NOW()
FROM public.profiles p
WHERE NOT EXISTS (SELECT 1 FROM public.customers c WHERE c.user_id = p.id)
ON CONFLICT (user_id) DO NOTHING;