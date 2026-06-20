-- Fix: create_and_send_broadcast() calls send_broadcast_message(uuid, uuid)
-- This overload still referenced the non-existent table user_notifications.
-- We align it with the uuid-only overload by writing into public.notifications.

CREATE OR REPLACE FUNCTION public.send_broadcast_message(
  p_broadcast_id uuid,
  p_sender_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_broadcast broadcast_messages%ROWTYPE;
  v_recipient RECORD;
  v_count INTEGER := 0;
BEGIN
  -- p_sender_id currently not used, kept for backward compatibility

  -- Récupérer le broadcast
  SELECT * INTO v_broadcast FROM broadcast_messages WHERE id = p_broadcast_id;

  IF v_broadcast IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Broadcast not found');
  END IF;

  IF v_broadcast.status NOT IN ('draft', 'scheduled') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Broadcast already sent or cancelled');
  END IF;

  -- Mettre à jour le statut
  UPDATE broadcast_messages
  SET status = 'sending', updated_at = NOW()
  WHERE id = p_broadcast_id;

  -- Insérer les destinataires
  FOR v_recipient IN
    SELECT * FROM get_broadcast_target_users(
      v_broadcast.target_segment,
      v_broadcast.target_roles,
      v_broadcast.target_regions,
      v_broadcast.target_user_ids
    )
  LOOP
    -- Insérer dans broadcast_recipients
    INSERT INTO broadcast_recipients (broadcast_id, user_id, channel)
    VALUES (p_broadcast_id, v_recipient.user_id, 'internal')
    ON CONFLICT (broadcast_id, user_id) DO NOTHING;

    -- Créer une notification interne dans la table 'notifications'
    INSERT INTO notifications (
      user_id, type, title, message, read
    ) VALUES (
      v_recipient.user_id,
      'system',
      v_broadcast.title,
      LEFT(v_broadcast.content, 200),
      false
    );

    v_count := v_count + 1;
  END LOOP;

  -- Mettre à jour le statut final
  UPDATE broadcast_messages
  SET
    status = 'sent',
    sent_at = NOW(),
    updated_at = NOW()
  WHERE id = p_broadcast_id;

  -- Créer les métriques initiales
  INSERT INTO broadcast_metrics (broadcast_id, total_recipients, total_delivered)
  VALUES (p_broadcast_id, v_count, v_count)
  ON CONFLICT (broadcast_id) DO UPDATE SET
    total_recipients = v_count,
    total_delivered = v_count,
    updated_at = NOW();

  RETURN jsonb_build_object(
    'success', true,
    'recipients_count', v_count,
    'broadcast_id', p_broadcast_id
  );
END;
$$;