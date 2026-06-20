-- ============================================
-- CORRECTION SYSTÈME DE COMMANDES - PARTIE 2
-- Créer les triggers et indexes
-- ============================================

-- 1. Trigger pour créer customer à l'inscription
DROP TRIGGER IF EXISTS create_customer_on_profile_insert ON public.profiles;
CREATE TRIGGER create_customer_on_profile_insert
  AFTER INSERT ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.create_customer_on_signup();

-- 2. Fonction de notification vendeur
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
  IF NEW.source = 'online' THEN
    SELECT user_id INTO v_vendor_user_id
    FROM public.vendors
    WHERE id = NEW.vendor_id;
    
    SELECT CONCAT(p.first_name, ' ', p.last_name) INTO v_customer_name
    FROM public.customers c
    JOIN public.profiles p ON c.user_id = p.id
    WHERE c.id = NEW.customer_id;
    
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
        CONCAT('Nouvelle commande #', NEW.order_number, ' de ', COALESCE(v_customer_name, 'Client'), ' - ', NEW.total_amount, ' GNF'),
        'order',
        FALSE,
        NOW()
      );
    END IF;
  END IF;
  
  RETURN NEW;
END;
$$;

-- 3. Trigger de notification
DROP TRIGGER IF EXISTS notify_vendor_on_new_order ON public.orders;
CREATE TRIGGER notify_vendor_on_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_vendor_new_order();

-- 4. Index pour performances
CREATE INDEX IF NOT EXISTS idx_orders_customer_source ON public.orders(customer_id, source);
CREATE INDEX IF NOT EXISTS idx_orders_vendor_source ON public.orders(vendor_id, source);
CREATE INDEX IF NOT EXISTS idx_customers_user_id ON public.customers(user_id);