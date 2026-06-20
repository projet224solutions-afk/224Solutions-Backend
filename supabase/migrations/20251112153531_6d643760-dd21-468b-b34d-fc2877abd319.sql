-- Fix: Corriger la fonction de notification vendeur pour utiliser les bonnes colonnes
DROP FUNCTION IF EXISTS public.notify_vendor_new_order() CASCADE;

CREATE OR REPLACE FUNCTION public.notify_vendor_new_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendor_user_id uuid;
  v_customer_name text;
  v_order_total numeric;
BEGIN
  -- Récupérer le user_id du vendeur
  SELECT user_id INTO v_vendor_user_id
  FROM vendors
  WHERE id = NEW.vendor_id;

  IF v_vendor_user_id IS NULL THEN
    RAISE WARNING 'Vendor user_id not found for vendor_id: %', NEW.vendor_id;
    RETURN NEW;
  END IF;

  -- Récupérer le nom du client
  SELECT COALESCE(
    (SELECT full_name FROM customers WHERE user_id = u.id),
    u.email, 
    'Client'
  ) INTO v_customer_name
  FROM auth.users u
  WHERE u.id = (SELECT user_id FROM customers WHERE id = NEW.customer_id);

  v_order_total := NEW.total_amount;

  -- Créer une notification pour le vendeur avec les bonnes colonnes (body et is_read)
  INSERT INTO communication_notifications (
    user_id,
    type,
    title,
    body,
    is_read,
    metadata
  ) VALUES (
    v_vendor_user_id,
    'order_created',
    'Nouvelle commande reçue',
    format('Vous avez reçu une nouvelle commande de %s pour un montant de %s GNF (N° %s)', 
           v_customer_name, 
           v_order_total::text, 
           NEW.order_number),
    false,
    jsonb_build_object(
      'order_id', NEW.id,
      'order_number', NEW.order_number,
      'customer_id', NEW.customer_id,
      'total_amount', NEW.total_amount,
      'source', NEW.source
    )
  );

  RETURN NEW;
END;
$$;

-- Recréer le trigger
DROP TRIGGER IF EXISTS trigger_notify_vendor_new_order ON public.orders;
CREATE TRIGGER trigger_notify_vendor_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  WHEN (NEW.source = 'online')
  EXECUTE FUNCTION public.notify_vendor_new_order();