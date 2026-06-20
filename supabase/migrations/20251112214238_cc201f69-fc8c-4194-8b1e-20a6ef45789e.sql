-- ============================================
-- CORRECTION EN PROFONDEUR: SYSTÈME DE COMMANDES CLIENT
-- ============================================

-- 1. Trigger pour créer automatiquement un customer lors de l'inscription
CREATE OR REPLACE FUNCTION public.create_customer_on_signup()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
BEGIN
  -- Créer un enregistrement customer pour chaque nouveau profil
  INSERT INTO public.customers (user_id, created_at, updated_at)
  VALUES (NEW.id, NOW(), NOW())
  ON CONFLICT (user_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;

-- Créer le trigger
DROP TRIGGER IF EXISTS create_customer_on_profile_insert ON public.profiles;
CREATE TRIGGER create_customer_on_profile_insert
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.create_customer_on_signup();

-- 2. S'assurer que tous les profils existants ont un customer
INSERT INTO public.customers (user_id, created_at, updated_at)
SELECT 
  p.id,
  NOW(),
  NOW()
FROM public.profiles p
WHERE NOT EXISTS (
  SELECT 1 FROM public.customers c WHERE c.user_id = p.id
)
ON CONFLICT (user_id) DO NOTHING;

-- 3. Fonction pour créer une commande en ligne (utilisée par le frontend)
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
    tax_amount,
    shipping_amount,
    discount_amount,
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
    0,
    0,
    0,
    'pending',
    CASE 
      WHEN p_payment_method = 'cash' THEN 'pending'
      ELSE 'paid'
    END,
    p_payment_method::payment_method,
    COALESCE(p_shipping_address, '{"address": "Conakry", "city": "Conakry", "country": "Guinée"}'::JSONB),
    'online',
    NOW(),
    NOW()
  )
  RETURNING id INTO v_order_id;
  
  -- Créer les items de commande
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    INSERT INTO public.order_items (
      order_id,
      product_id,
      quantity,
      unit_price,
      total_price,
      created_at
    ) VALUES (
      v_order_id,
      (v_item->>'product_id')::UUID,
      (v_item->>'quantity')::INTEGER,
      (v_item->>'price')::NUMERIC,
      (v_item->>'quantity')::INTEGER * (v_item->>'price')::NUMERIC,
      NOW()
    );
  END LOOP;
  
  -- Retourner les infos de la commande
  RETURN QUERY
  SELECT v_order_id, v_order_number, v_customer_id;
END;
$$;

-- 4. Améliorer les notifications pour les vendeurs (commandes en ligne)
CREATE OR REPLACE FUNCTION public.notify_vendor_new_order()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
LANGUAGE plpgsql
AS $$
DECLARE
  v_vendor_user_id UUID;
  v_customer_name TEXT;
BEGIN
  -- Uniquement pour les commandes en ligne
  IF NEW.source = 'online' THEN
    -- Récupérer le user_id du vendeur
    SELECT user_id INTO v_vendor_user_id
    FROM public.vendors
    WHERE id = NEW.vendor_id;
    
    -- Récupérer le nom du client
    SELECT CONCAT(p.first_name, ' ', p.last_name) INTO v_customer_name
    FROM public.customers c
    JOIN public.profiles p ON c.user_id = p.id
    WHERE c.id = NEW.customer_id;
    
    -- Créer une notification pour le vendeur
    IF v_vendor_user_id IS NOT NULL THEN
      INSERT INTO public.communication_notifications (
        user_id,
        title,
        body,
        type,
        is_read,
        created_at
      ) VALUES (
        v_vendor_user_id,
        'Nouvelle commande en ligne',
        CONCAT('Nouvelle commande #', NEW.order_number, ' de ', COALESCE(v_customer_name, 'Client'), ' - Montant: ', NEW.total_amount, ' GNF'),
        'order',
        FALSE,
        NOW()
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

-- Recréer le trigger de notification
DROP TRIGGER IF EXISTS notify_vendor_on_new_order ON public.orders;
CREATE TRIGGER notify_vendor_on_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_vendor_new_order();

-- 5. Index pour améliorer les performances
CREATE INDEX IF NOT EXISTS idx_orders_customer_source ON public.orders(customer_id, source);
CREATE INDEX IF NOT EXISTS idx_orders_vendor_source ON public.orders(vendor_id, source);
CREATE INDEX IF NOT EXISTS idx_customers_user_id ON public.customers(user_id);

COMMENT ON FUNCTION public.create_online_order IS 'Crée une commande en ligne avec tous les items associés';
COMMENT ON FUNCTION public.create_customer_on_signup IS 'Crée automatiquement un customer lors de la création d''un profil';
COMMENT ON FUNCTION public.notify_vendor_new_order IS 'Notifie le vendeur lors d''une nouvelle commande en ligne';