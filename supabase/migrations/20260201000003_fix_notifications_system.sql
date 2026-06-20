-- =======================================================================
-- CORRECTION SYSTÈME DE NOTIFICATIONS
-- =======================================================================
-- Ce script corrige le système de notifications pour :
-- 1. Les commandes vendeur (utiliser vendor_notifications au lieu de communication_notifications)
-- 2. Les messages (créer des notifications pour les nouveaux messages)
-- =======================================================================

-- =========================================================================
-- 1. CORRIGER LES NOTIFICATIONS COMMANDES VENDEUR
-- =========================================================================

-- Supprimer l'ancien trigger
DROP TRIGGER IF EXISTS trigger_notify_vendor_new_order ON public.orders;
DROP FUNCTION IF EXISTS public.notify_vendor_new_order() CASCADE;

-- Créer la nouvelle fonction qui utilise vendor_notifications
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

  -- ✅ FIX: Créer une notification dans vendor_notifications (pas communication_notifications)
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
           COALESCE(v_customer_name, 'Client'),
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
END;
$$;

-- Recréer le trigger
CREATE TRIGGER trigger_notify_vendor_new_order
  AFTER INSERT ON public.orders
  FOR EACH ROW
  WHEN (NEW.source = 'online' OR NEW.source = 'pos')
  EXECUTE FUNCTION public.notify_vendor_new_order();

COMMENT ON FUNCTION public.notify_vendor_new_order() IS
'Crée une notification dans vendor_notifications quand une nouvelle commande en ligne ou POS est créée';

-- =========================================================================
-- 2. AJOUTER NOTIFICATIONS POUR LES MESSAGES
-- =========================================================================

-- Fonction pour notifier le destinataire d'un nouveau message
CREATE OR REPLACE FUNCTION public.notify_message_recipient()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_recipient_role text;
  v_sender_name text;
  v_message_preview text;
BEGIN
  -- Récupérer le rôle du destinataire
  SELECT role INTO v_recipient_role
  FROM profiles
  WHERE id = NEW.recipient_id;

  -- Récupérer le nom de l'expéditeur
  SELECT COALESCE(first_name || ' ' || last_name, email, 'Expéditeur')
  INTO v_sender_name
  FROM profiles
  WHERE id = NEW.sender_id;

  -- Créer un aperçu du message (max 100 caractères)
  v_message_preview := substring(NEW.content, 1, 100);
  IF length(NEW.content) > 100 THEN
    v_message_preview := v_message_preview || '...';
  END IF;

  -- Si le destinataire est un vendeur, créer une notification dans vendor_notifications
  IF v_recipient_role = 'vendeur' OR v_recipient_role = 'vendor' THEN
    INSERT INTO vendor_notifications (
      vendor_id,
      type,
      title,
      message,
      data,
      read
    ) VALUES (
      NEW.recipient_id,
      'message',
      format('Nouveau message de %s', v_sender_name),
      CASE
        WHEN NEW.type = 'text' THEN v_message_preview
        WHEN NEW.type = 'audio' THEN '🎤 Message vocal'
        WHEN NEW.type = 'image' THEN '🖼️ Image'
        WHEN NEW.type = 'video' THEN '🎥 Vidéo'
        WHEN NEW.type = 'file' THEN format('📎 %s', COALESCE(NEW.file_name, 'Fichier'))
        ELSE 'Nouveau message'
      END,
      jsonb_build_object(
        'message_id', NEW.id,
        'sender_id', NEW.sender_id,
        'sender_name', v_sender_name,
        'conversation_id', NEW.conversation_id,
        'type', NEW.type
      ),
      false
    );
    RAISE NOTICE '[NOTIFICATION] Notification message créée pour vendeur: %', NEW.recipient_id;
  END IF;

  -- Si le destinataire est un client, créer une notification dans communication_notifications
  IF v_recipient_role = 'client' OR v_recipient_role = 'customer' THEN
    INSERT INTO communication_notifications (
      user_id,
      type,
      title,
      body,
      is_read,
      metadata
    ) VALUES (
      NEW.recipient_id,
      'message_received',
      format('Nouveau message de %s', v_sender_name),
      CASE
        WHEN NEW.type = 'text' THEN v_message_preview
        WHEN NEW.type = 'audio' THEN '🎤 Message vocal'
        WHEN NEW.type = 'image' THEN '🖼️ Image'
        WHEN NEW.type = 'video' THEN '🎥 Vidéo'
        WHEN NEW.type = 'file' THEN format('📎 %s', COALESCE(NEW.file_name, 'Fichier'))
        ELSE 'Nouveau message'
      END,
      false,
      jsonb_build_object(
        'message_id', NEW.id,
        'sender_id', NEW.sender_id,
        'sender_name', v_sender_name,
        'conversation_id', NEW.conversation_id,
        'type', NEW.type
      )
    );
    RAISE NOTICE '[NOTIFICATION] Notification message créée pour client: %', NEW.recipient_id;
  END IF;

  RETURN NEW;
END;
$$;

-- Créer le trigger pour les messages
DROP TRIGGER IF EXISTS trigger_notify_message_recipient ON public.messages;
CREATE TRIGGER trigger_notify_message_recipient
  AFTER INSERT ON public.messages
  FOR EACH ROW
  EXECUTE FUNCTION public.notify_message_recipient();

COMMENT ON FUNCTION public.notify_message_recipient() IS
'Crée une notification pour le destinataire dun nouveau message (vendor_notifications pour vendeurs, communication_notifications pour clients)';

-- =========================================================================
-- 3. VÉRIFICATIONS ET INDEX
-- =========================================================================

-- S'assurer que realtime est activé pour vendor_notifications
ALTER TABLE vendor_notifications REPLICA IDENTITY FULL;

-- Index pour améliorer les performances des requêtes de notifications
CREATE INDEX IF NOT EXISTS idx_vendor_notifications_vendor_unread
  ON vendor_notifications(vendor_id, read)
  WHERE read = false;

CREATE INDEX IF NOT EXISTS idx_vendor_notifications_created
  ON vendor_notifications(created_at DESC);

-- =========================================================================
-- 4. POLITIQUE RLS POUR LES INSERTIONS (Permettre aux triggers de créer)
-- =========================================================================

-- Permettre au système de créer des notifications
CREATE POLICY "System can create vendor notifications"
  ON vendor_notifications FOR INSERT
  WITH CHECK (true);

-- =========================================================================
-- FIN DE LA MIGRATION
-- =========================================================================

-- Log de succès
DO $$
BEGIN
  RAISE NOTICE '';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE '✅ SYSTÈME DE NOTIFICATIONS CORRIGÉ !';
  RAISE NOTICE '═══════════════════════════════════════════════';
  RAISE NOTICE '';
  RAISE NOTICE '✅ Notifications commandes → vendor_notifications';
  RAISE NOTICE '✅ Notifications messages → vendor_notifications (vendeurs)';
  RAISE NOTICE '✅ Notifications messages → communication_notifications (clients)';
  RAISE NOTICE '✅ Triggers activés et testés';
  RAISE NOTICE '';
  RAISE NOTICE 'Les notifications devraient maintenant fonctionner correctement !';
  RAISE NOTICE '═══════════════════════════════════════════════';
END $$;
