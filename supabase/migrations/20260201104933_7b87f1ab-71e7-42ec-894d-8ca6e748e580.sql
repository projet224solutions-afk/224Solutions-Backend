-- Corriger le trigger notify_vendor_new_order pour utiliser profiles.full_name au lieu de customers.full_name

CREATE OR REPLACE FUNCTION notify_vendor_new_order()
RETURNS TRIGGER AS $$
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

  -- Récupérer le nom du client depuis profiles (pas customers)
  SELECT COALESCE(p.full_name, p.first_name || ' ' || p.last_name, p.email, 'Client')
  INTO v_customer_name
  FROM customers c
  LEFT JOIN profiles p ON c.user_id = p.id
  WHERE c.id = NEW.customer_id;

  -- Fallback si pas trouvé
  IF v_customer_name IS NULL THEN
    v_customer_name := 'Client';
  END IF;

  v_order_total := NEW.total_amount;

  -- Créer une notification dans vendor_notifications
  INSERT INTO vendor_notifications (
    vendor_id,
    type,
    title,
    message,
    data,
    read
  ) VALUES (
    v_vendor_user_id,
    'order',
    'Nouvelle commande reçue',
    format('Vous avez reçu une nouvelle commande de %s pour un montant de %s GNF (N° %s)',
           v_customer_name,
           COALESCE(v_order_total::text, '0'),
           NEW.order_number),
    jsonb_build_object(
      'order_id', NEW.id,
      'order_number', NEW.order_number,
      'customer_id', NEW.customer_id,
      'total_amount', NEW.total_amount,
      'source', NEW.source
    ),
    false
  );

  RAISE NOTICE '[NOTIFICATION] Notification commande créée pour vendeur: %', v_vendor_user_id;
  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Ne pas bloquer la commande en cas d'erreur de notification
    RAISE WARNING '[NOTIFICATION] Erreur création notification: %', SQLERRM;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;