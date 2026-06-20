-- Corriger les RLS policies pour permettre la création de commandes en ligne
-- et ajouter un trigger de notification pour les vendeurs

-- 1. Vérifier et corriger les policies INSERT sur orders
DROP POLICY IF EXISTS "Allow anyone to create orders" ON public.orders;
CREATE POLICY "Clients can create their own orders"
  ON public.orders
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.customers
      WHERE customers.id = orders.customer_id
      AND customers.user_id = auth.uid()
    )
  );

-- 2. S'assurer que les clients peuvent voir leurs commandes en ligne
DROP POLICY IF EXISTS "Customers can view their own orders" ON public.orders;
CREATE POLICY "Customers can view their own orders"
  ON public.orders
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.customers
      WHERE customers.id = orders.customer_id
      AND customers.user_id = auth.uid()
    )
  );

-- 3. S'assurer que les vendeurs peuvent voir et mettre à jour leurs commandes
DROP POLICY IF EXISTS "Vendors can view their orders" ON public.orders;
CREATE POLICY "Vendors can view their orders"
  ON public.orders
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.vendors
      WHERE vendors.id = orders.vendor_id
      AND vendors.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "Vendors can update their orders" ON public.orders;
CREATE POLICY "Vendors can update their orders"
  ON public.orders
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.vendors
      WHERE vendors.id = orders.vendor_id
      AND vendors.user_id = auth.uid()
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.vendors
      WHERE vendors.id = orders.vendor_id
      AND vendors.user_id = auth.uid()
    )
  );

-- 4. Créer une fonction pour notifier le vendeur d'une nouvelle commande
CREATE OR REPLACE FUNCTION notify_vendor_new_order()
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
  FROM public.vendors
  WHERE id = NEW.vendor_id;

  -- Récupérer le nom du client
  SELECT COALESCE(full_name, email, 'Client') INTO v_customer_name
  FROM auth.users
  WHERE id = (SELECT user_id FROM public.customers WHERE id = NEW.customer_id);

  v_order_total := NEW.total_amount;

  -- Créer une notification pour le vendeur
  INSERT INTO public.communication_notifications (
    user_id,
    title,
    message,
    type,
    metadata,
    read
  ) VALUES (
    v_vendor_user_id,
    'Nouvelle commande reçue',
    format('Vous avez reçu une nouvelle commande de %s pour un montant de %s GNF (N° %s)', 
           v_customer_name, 
           v_order_total::text, 
           NEW.order_number),
    'order_created',
    jsonb_build_object(
      'order_id', NEW.id,
      'order_number', NEW.order_number,
      'customer_id', NEW.customer_id,
      'total_amount', NEW.total_amount,
      'source', NEW.source
    ),
    false
  );

  RETURN NEW;
END;
$$;

-- 5. Créer le trigger pour notifier automatiquement
DROP TRIGGER IF EXISTS trigger_notify_vendor_new_order ON public.orders;
CREATE TRIGGER trigger_notify_vendor_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  WHEN (NEW.source = 'online')
  EXECUTE FUNCTION notify_vendor_new_order();