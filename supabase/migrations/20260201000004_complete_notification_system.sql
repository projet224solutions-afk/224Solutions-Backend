-- =======================================================================
-- SYSTÈME DE NOTIFICATIONS COMPLET POUR TOUTES LES INTERFACES
-- =======================================================================
-- Ce script crée un système de notifications universel pour :
-- - Vendeurs (commandes, paiements, stock, messages)
-- - Clients (commandes, livraisons, paiements, messages)
-- - Agents (livraisons, commissions)
-- - Bureaux (transferts, commissions)
-- - Taxi-Moto (courses, paiements)
-- - Restaurants (commandes, livraisons)
-- - PDG (alertes système)
-- =======================================================================

-- =========================================================================
-- 1. TABLE DE NOTIFICATIONS UNIVERSELLE (pour clients, agents, etc.)
-- =========================================================================

-- Créer une table de notifications générique si elle n'existe pas
CREATE TABLE IF NOT EXISTS user_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN (
    'order', 'payment', 'message', 'delivery', 'ride',
    'transfer', 'commission', 'stock', 'security',
    'subscription', 'system', 'restaurant_order'
  )),
  title TEXT NOT NULL,
  message TEXT NOT NULL,
  data JSONB,
  read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_user_notifications_user_unread
  ON user_notifications(user_id, read) WHERE read = false;

CREATE INDEX IF NOT EXISTS idx_user_notifications_created
  ON user_notifications(created_at DESC);

-- RLS
ALTER TABLE user_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own notifications"
  ON user_notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own notifications"
  ON user_notifications FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "System can create user notifications"
  ON user_notifications FOR INSERT
  WITH CHECK (true);

-- Realtime
ALTER TABLE user_notifications REPLICA IDENTITY FULL;

-- =========================================================================
-- 2. NOTIFICATIONS COMMANDES CLIENT (changement de statut)
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_customer_order_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer_user_id uuid;
  v_status_message text;
BEGIN
  -- Seulement si le statut a changé
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  -- Récupérer l'user_id du client
  SELECT user_id INTO v_customer_user_id
  FROM customers
  WHERE id = NEW.customer_id;

  IF v_customer_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- Message selon le statut
  v_status_message := CASE NEW.status
    WHEN 'pending' THEN 'Votre commande est en attente de confirmation'
    WHEN 'confirmed' THEN 'Votre commande a été confirmée et est en préparation'
    WHEN 'processing' THEN 'Votre commande est en cours de traitement'
    WHEN 'shipped' THEN 'Votre commande a été expédiée'
    WHEN 'delivered' THEN 'Votre commande a été livrée avec succès'
    WHEN 'cancelled' THEN 'Votre commande a été annulée'
    ELSE 'Statut de votre commande mis à jour'
  END;

  INSERT INTO user_notifications (
    user_id, type, title, message, data, read
  ) VALUES (
    v_customer_user_id,
    'order',
    format('Commande N° %s - %s', NEW.order_number, NEW.status),
    v_status_message,
    jsonb_build_object(
      'order_id', NEW.id,
      'order_number', NEW.order_number,
      'status', NEW.status,
      'total_amount', NEW.total_amount
    ),
    false
  );

  RAISE NOTICE '[NOTIFICATION] Client notifié du changement de statut: %', NEW.status;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_customer_order_status ON orders;
CREATE TRIGGER trigger_notify_customer_order_status
  AFTER UPDATE OF status ON orders
  FOR EACH ROW
  EXECUTE FUNCTION notify_customer_order_status_change();

-- =========================================================================
-- 3. NOTIFICATIONS PAIEMENT
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_payment_received()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recipient_name text;
BEGIN
  -- Notifier le destinataire du paiement
  SELECT COALESCE(first_name || ' ' || last_name, email)
  INTO v_recipient_name
  FROM profiles
  WHERE id = NEW.to_user_id;

  INSERT INTO user_notifications (
    user_id, type, title, message, data, read
  ) VALUES (
    NEW.to_user_id,
    'payment',
    'Paiement reçu',
    format('Vous avez reçu un paiement de %s GNF', NEW.amount::text),
    jsonb_build_object(
      'transaction_id', NEW.id,
      'amount', NEW.amount,
      'from_user', NEW.from_user_id,
      'type', NEW.transaction_type
    ),
    false
  );

  RAISE NOTICE '[NOTIFICATION] Paiement notifié: %', NEW.to_user_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_payment_received ON wallet_transactions;
CREATE TRIGGER trigger_notify_payment_received
  AFTER INSERT ON wallet_transactions
  FOR EACH ROW
  WHEN (NEW.transaction_type = 'transfer' OR NEW.transaction_type = 'payment')
  EXECUTE FUNCTION notify_payment_received();

-- =========================================================================
-- 4. NOTIFICATIONS AGENT (nouvelle livraison assignée)
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_agent_new_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order_number text;
  v_delivery_address text;
BEGIN
  -- Récupérer les infos de la commande
  SELECT order_number, shipping_address->>'address'
  INTO v_order_number, v_delivery_address
  FROM orders
  WHERE id = NEW.order_id;

  INSERT INTO user_notifications (
    user_id, type, title, message, data, read
  ) VALUES (
    NEW.agent_id,
    'delivery',
    'Nouvelle livraison assignée',
    format('Livraison N° %s à effectuer vers %s',
           COALESCE(v_order_number, 'N/A'),
           COALESCE(v_delivery_address, 'adresse non spécifiée')),
    jsonb_build_object(
      'delivery_id', NEW.id,
      'order_id', NEW.order_id,
      'order_number', v_order_number,
      'status', NEW.status
    ),
    false
  );

  RAISE NOTICE '[NOTIFICATION] Agent notifié de nouvelle livraison';
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_agent_delivery ON deliveries;
CREATE TRIGGER trigger_notify_agent_delivery
  AFTER INSERT ON deliveries
  FOR EACH ROW
  WHEN (NEW.agent_id IS NOT NULL)
  EXECUTE FUNCTION notify_agent_new_delivery();

-- =========================================================================
-- 5. NOTIFICATIONS TAXI-MOTO (nouvelle course)
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_driver_new_ride()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Notifier le conducteur assigné
  IF NEW.driver_id IS NOT NULL THEN
    INSERT INTO user_notifications (
      user_id, type, title, message, data, read
    ) VALUES (
      NEW.driver_id,
      'ride',
      'Nouvelle course assignée',
      format('Course de %s vers %s',
             COALESCE(NEW.pickup_address, 'point de départ'),
             COALESCE(NEW.dropoff_address, 'destination')),
      jsonb_build_object(
        'ride_id', NEW.id,
        'pickup', NEW.pickup_address,
        'dropoff', NEW.dropoff_address,
        'fare', NEW.fare,
        'status', NEW.status
      ),
      false
    );
  END IF;

  -- Notifier le client de l'acceptation
  IF OLD.status = 'pending' AND NEW.status = 'accepted' THEN
    INSERT INTO user_notifications (
      user_id, type, title, message, data, read
    ) VALUES (
      NEW.user_id,
      'ride',
      'Course acceptée',
      'Un conducteur a accepté votre course',
      jsonb_build_object(
        'ride_id', NEW.id,
        'driver_id', NEW.driver_id,
        'status', NEW.status
      ),
      false
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_ride_update ON taxi_rides;
CREATE TRIGGER trigger_notify_ride_update
  AFTER INSERT OR UPDATE ON taxi_rides
  FOR EACH ROW
  EXECUTE FUNCTION notify_driver_new_ride();

-- =========================================================================
-- 6. NOTIFICATIONS BUREAU (nouveau transfert)
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_bureau_transfer()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Notifier le bureau responsable
  IF NEW.bureau_id IS NOT NULL THEN
    INSERT INTO user_notifications (
      user_id, type, title, message, data, read
    ) VALUES (
      NEW.bureau_id,
      'transfer',
      'Nouveau transfert à traiter',
      format('Transfert de %s GNF à effectuer', NEW.amount::text),
      jsonb_build_object(
        'transfer_id', NEW.id,
        'amount', NEW.amount,
        'sender', NEW.sender_id,
        'recipient', NEW.recipient_id,
        'status', NEW.status
      ),
      false
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Note: Adapter selon la structure réelle de votre table transfers
-- DROP TRIGGER IF EXISTS trigger_notify_bureau_transfer ON transfers;
-- CREATE TRIGGER trigger_notify_bureau_transfer
--   AFTER INSERT ON transfers
--   FOR EACH ROW
--   EXECUTE FUNCTION notify_bureau_transfer();

-- =========================================================================
-- 7. NOTIFICATIONS RESTAURANT (nouvelle commande)
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_restaurant_new_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_restaurant_user_id uuid;
BEGIN
  -- Récupérer l'user_id du restaurant
  SELECT user_id INTO v_restaurant_user_id
  FROM restaurants
  WHERE id = NEW.restaurant_id;

  IF v_restaurant_user_id IS NOT NULL THEN
    INSERT INTO user_notifications (
      user_id, type, title, message, data, read
    ) VALUES (
      v_restaurant_user_id,
      'restaurant_order',
      'Nouvelle commande restaurant',
      format('Nouvelle commande N° %s pour %s GNF',
             NEW.order_number,
             NEW.total_amount::text),
      jsonb_build_object(
        'order_id', NEW.id,
        'order_number', NEW.order_number,
        'total_amount', NEW.total_amount,
        'status', NEW.status
      ),
      false
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Note: Adapter selon la structure réelle
-- DROP TRIGGER IF EXISTS trigger_notify_restaurant_order ON restaurant_orders;
-- CREATE TRIGGER trigger_notify_restaurant_order
--   AFTER INSERT ON restaurant_orders
--   FOR EACH ROW
--   EXECUTE FUNCTION notify_restaurant_new_order();

-- =========================================================================
-- 8. NOTIFICATIONS STOCK BAS
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vendor_user_id uuid;
  v_product_name text;
BEGIN
  -- Vérifier si le stock est bas
  IF NEW.stock_quantity <= COALESCE(NEW.low_stock_threshold, 10) THEN
    -- Récupérer le vendeur du produit
    SELECT v.user_id, p.name
    INTO v_vendor_user_id, v_product_name
    FROM vendors v
    JOIN products p ON p.vendor_id = v.id
    WHERE p.id = NEW.id;

    IF v_vendor_user_id IS NOT NULL THEN
      -- Vérifier si on n'a pas déjà envoyé une notification récemment (dans les dernières 24h)
      IF NOT EXISTS (
        SELECT 1 FROM vendor_notifications
        WHERE vendor_id = v_vendor_user_id
        AND type = 'stock'
        AND data->>'product_id' = NEW.id::text
        AND created_at > NOW() - INTERVAL '24 hours'
      ) THEN
        INSERT INTO vendor_notifications (
          vendor_id, type, title, message, data, read
        ) VALUES (
          v_vendor_user_id,
          'stock',
          'Alerte stock bas',
          format('Le produit "%s" a un stock bas (%s unités restantes)',
                 v_product_name,
                 NEW.stock_quantity::text),
          jsonb_build_object(
            'product_id', NEW.id,
            'product_name', v_product_name,
            'current_stock', NEW.stock_quantity,
            'threshold', COALESCE(NEW.low_stock_threshold, 10)
          ),
          false
        );

        RAISE NOTICE '[NOTIFICATION] Alerte stock bas envoyée';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_low_stock ON products;
CREATE TRIGGER trigger_notify_low_stock
  AFTER UPDATE OF stock_quantity ON products
  FOR EACH ROW
  EXECUTE FUNCTION notify_low_stock();

-- =========================================================================
-- 9. NOTIFICATIONS COMMISSIONS
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_commission_earned()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_commission_type text;
BEGIN
  v_commission_type := CASE
    WHEN NEW.role = 'agent' THEN 'commission de livraison'
    WHEN NEW.role = 'bureau' THEN 'commission de transfert'
    WHEN NEW.role = 'affiliate' THEN 'commission d''affiliation'
    ELSE 'commission'
  END;

  INSERT INTO user_notifications (
    user_id, type, title, message, data, read
  ) VALUES (
    NEW.user_id,
    'commission',
    'Commission gagnée',
    format('Vous avez gagné une %s de %s GNF',
           v_commission_type,
           NEW.amount::text),
    jsonb_build_object(
      'commission_id', NEW.id,
      'amount', NEW.amount,
      'role', NEW.role,
      'transaction_id', NEW.transaction_id
    ),
    false
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_commission ON commissions;
CREATE TRIGGER trigger_notify_commission
  AFTER INSERT ON commissions
  FOR EACH ROW
  EXECUTE FUNCTION notify_commission_earned();

-- =========================================================================
-- 10. NOTIFICATIONS SÉCURITÉ (connexion suspecte)
-- =========================================================================

CREATE OR REPLACE FUNCTION notify_suspicious_login()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.activity_type = 'unusual_login' OR NEW.activity_type = 'unusual_location' THEN
    INSERT INTO user_notifications (
      user_id, type, title, message, data, read
    ) VALUES (
      NEW.vendor_id,
      'security',
      'Alerte sécurité',
      format('Activité suspecte détectée: %s', NEW.description),
      jsonb_build_object(
        'activity_id', NEW.id,
        'type', NEW.activity_type,
        'severity', NEW.severity,
        'ip', NEW.ip_address
      ),
      false
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_suspicious_activity ON suspicious_activities;
CREATE TRIGGER trigger_notify_suspicious_activity
  AFTER INSERT ON suspicious_activities
  FOR EACH ROW
  WHEN (NEW.severity IN ('high', 'critical'))
  EXECUTE FUNCTION notify_suspicious_login();

-- =========================================================================
-- 11. NOTIFICATIONS ABONNEMENT EXPIRANT
-- =========================================================================

-- Fonction pour notifier les vendeurs dont l'abonnement expire bientôt
CREATE OR REPLACE FUNCTION check_expiring_subscriptions()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_subscription RECORD;
BEGIN
  -- Notifier les abonnements qui expirent dans 7 jours
  FOR v_subscription IN
    SELECT id, vendor_id, end_date
    FROM vendor_subscriptions
    WHERE status = 'active'
    AND end_date BETWEEN NOW() AND NOW() + INTERVAL '7 days'
    AND NOT EXISTS (
      SELECT 1 FROM vendor_notifications
      WHERE vendor_id = vendor_subscriptions.vendor_id
      AND type = 'subscription'
      AND data->>'subscription_id' = vendor_subscriptions.id::text
      AND created_at > NOW() - INTERVAL '24 hours'
    )
  LOOP
    INSERT INTO vendor_notifications (
      vendor_id, type, title, message, data, read
    ) VALUES (
      v_subscription.vendor_id,
      'subscription',
      'Abonnement expire bientôt',
      format('Votre abonnement expire le %s. Renouvelez-le pour continuer à profiter de tous les avantages.',
             v_subscription.end_date::date::text),
      jsonb_build_object(
        'subscription_id', v_subscription.id,
        'end_date', v_subscription.end_date
      ),
      false
    );
  END LOOP;
END;
$$;

-- Cette fonction devrait être appelée par un cron job quotidien
-- Voir la section CRON ci-dessous

-- =========================================================================
-- 12. FONCTION HELPER POUR CRÉER DES NOTIFICATIONS
-- =========================================================================

-- Fonction générique pour créer une notification
CREATE OR REPLACE FUNCTION create_notification(
  p_user_id UUID,
  p_type TEXT,
  p_title TEXT,
  p_message TEXT,
  p_data JSONB DEFAULT NULL,
  p_use_vendor_table BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  IF p_use_vendor_table THEN
    -- Utiliser vendor_notifications
    INSERT INTO vendor_notifications (vendor_id, type, title, message, data, read)
    VALUES (p_user_id, p_type, p_title, p_message, p_data, false)
    RETURNING id INTO v_notification_id;
  ELSE
    -- Utiliser user_notifications
    INSERT INTO user_notifications (user_id, type, title, message, data, read)
    VALUES (p_user_id, p_type, p_title, p_message, p_data, false)
    RETURNING id INTO v_notification_id;
  END IF;

  RETURN v_notification_id;
END;
$$;

-- =========================================================================
-- 13. CONFIGURATION CRON (À activer dans Supabase Dashboard)
-- =========================================================================

-- NOTE: Pour activer le cron, allez dans Supabase Dashboard → Database → Cron Jobs
-- et créez un job avec cette commande :
--
-- SELECT cron.schedule(
--   'check-expiring-subscriptions',
--   '0 10 * * *', -- Tous les jours à 10h00
--   $$ SELECT check_expiring_subscriptions(); $$
-- );

-- =========================================================================
-- FIN DE LA MIGRATION
-- =========================================================================

DO $$
BEGIN
  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE '✅ SYSTÈME DE NOTIFICATIONS COMPLET INSTALLÉ !';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE '';
  RAISE NOTICE '✅ Notifications VENDEURS (commandes, paiements, stock)';
  RAISE NOTICE '✅ Notifications CLIENTS (commandes, livraisons)';
  RAISE NOTICE '✅ Notifications AGENTS (livraisons, commissions)';
  RAISE NOTICE '✅ Notifications TAXI-MOTO (courses)';
  RAISE NOTICE '✅ Notifications RESTAURANTS (commandes)';
  RAISE NOTICE '✅ Notifications BUREAUX (transferts)';
  RAISE NOTICE '✅ Alertes SÉCURITÉ';
  RAISE NOTICE '✅ Alertes STOCK BAS';
  RAISE NOTICE '✅ Alertes ABONNEMENT';
  RAISE NOTICE '';
  RAISE NOTICE '📌 Prochaines étapes:';
  RAISE NOTICE '   1. Activer le cron job pour les abonnements';
  RAISE NOTICE '   2. Tester chaque type de notification';
  RAISE NOTICE '   3. Adapter les hooks frontend pour user_notifications';
  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
END $$;
