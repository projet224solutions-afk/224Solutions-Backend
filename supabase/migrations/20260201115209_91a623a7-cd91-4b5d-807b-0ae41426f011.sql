-- Fix: communication_notifications.type check constraint violations
-- Cause: trigger functions insert invalid type values (e.g., 'message_received', 'dispute')

CREATE OR REPLACE FUNCTION public.notify_message_recipient()
RETURNS trigger
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
      'new_message',
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

CREATE OR REPLACE FUNCTION public.notify_vendor_of_dispute()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO communication_notifications (user_id, type, title, body, metadata)
  VALUES (
    NEW.vendor_id,
    'system',
    'Nouveau litige ouvert',
    'Un client a ouvert un litige sur la commande ' || NEW.dispute_number,
    jsonb_build_object('dispute_id', NEW.id, 'order_id', NEW.order_id)
  );

  RETURN NEW;
END;
$$;