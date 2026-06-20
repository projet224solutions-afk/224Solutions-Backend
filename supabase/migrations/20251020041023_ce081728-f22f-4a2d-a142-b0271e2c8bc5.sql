-- Amélioration des tables de communication existantes

-- Ajouter colonnes manquantes à messages si besoin
ALTER TABLE messages ADD COLUMN IF NOT EXISTS type TEXT DEFAULT 'text' CHECK (type IN ('text', 'image', 'video', 'file', 'audio'));
ALTER TABLE messages ADD COLUMN IF NOT EXISTS file_url TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS file_name TEXT;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS file_size INTEGER;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS status TEXT DEFAULT 'sent' CHECK (status IN ('sent', 'delivered', 'read'));
ALTER TABLE messages ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

-- Ajouter colonnes manquantes à conversations
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_at TIMESTAMP WITH TIME ZONE;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_message_preview TEXT;

-- Ajouter colonnes manquantes à calls
ALTER TABLE calls ADD COLUMN IF NOT EXISTS duration INTEGER DEFAULT 0;
ALTER TABLE calls ADD COLUMN IF NOT EXISTS quality_rating INTEGER CHECK (quality_rating >= 1 AND quality_rating <= 5);
ALTER TABLE calls ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

-- Créer table pour audit des communications
CREATE TABLE IF NOT EXISTS communication_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  action_type TEXT NOT NULL CHECK (action_type IN ('message_sent', 'message_read', 'call_started', 'call_ended', 'conversation_created')),
  target_id UUID,
  metadata JSONB DEFAULT '{}'::jsonb,
  ip_address TEXT,
  user_agent TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Créer table pour notifications de communication
CREATE TABLE IF NOT EXISTS communication_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type TEXT NOT NULL CHECK (type IN ('new_message', 'missed_call', 'call_incoming')),
  conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
  message_id UUID REFERENCES messages(id) ON DELETE CASCADE,
  call_id UUID REFERENCES calls(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  is_read BOOLEAN DEFAULT false,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created ON messages(conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status) WHERE status != 'read';
CREATE INDEX IF NOT EXISTS idx_communication_notifications_user_unread ON communication_notifications(user_id) WHERE is_read = false;
CREATE INDEX IF NOT EXISTS idx_communication_audit_logs_user_created ON communication_audit_logs(user_id, created_at DESC);

-- RLS Policies pour audit logs
ALTER TABLE communication_audit_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own audit logs"
  ON communication_audit_logs FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Service role can insert audit logs"
  ON communication_audit_logs FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- RLS Policies pour notifications
ALTER TABLE communication_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own notifications"
  ON communication_notifications FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update their own notifications"
  ON communication_notifications FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Service role can insert notifications"
  ON communication_notifications FOR INSERT
  WITH CHECK (auth.role() = 'service_role');

-- Fonction pour marquer les messages comme lus
CREATE OR REPLACE FUNCTION mark_messages_as_read(p_conversation_id UUID, p_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE messages
  SET status = 'read'
  WHERE conversation_id = p_conversation_id
    AND sender_id != p_user_id
    AND status != 'read';
END;
$$;

-- Fonction pour créer une notification
CREATE OR REPLACE FUNCTION create_communication_notification(
  p_user_id UUID,
  p_type TEXT,
  p_title TEXT,
  p_body TEXT,
  p_conversation_id UUID DEFAULT NULL,
  p_message_id UUID DEFAULT NULL,
  p_call_id UUID DEFAULT NULL,
  p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  INSERT INTO communication_notifications (
    user_id, type, title, body,
    conversation_id, message_id, call_id, metadata
  ) VALUES (
    p_user_id, p_type, p_title, p_body,
    p_conversation_id, p_message_id, p_call_id, p_metadata
  ) RETURNING id INTO v_notification_id;
  
  RETURN v_notification_id;
END;
$$;

-- Trigger pour notifications automatiques sur nouveaux messages
CREATE OR REPLACE FUNCTION notify_new_message()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_participant RECORD;
  v_sender_name TEXT;
BEGIN
  -- Récupérer le nom de l'expéditeur
  SELECT COALESCE(first_name || ' ' || last_name, email) INTO v_sender_name
  FROM profiles
  WHERE id = NEW.sender_id;
  
  -- Notifier tous les participants sauf l'expéditeur
  FOR v_participant IN 
    SELECT user_id 
    FROM conversation_participants 
    WHERE conversation_id = NEW.conversation_id 
      AND user_id != NEW.sender_id
  LOOP
    PERFORM create_communication_notification(
      v_participant.user_id,
      'new_message',
      'Nouveau message de ' || v_sender_name,
      LEFT(NEW.content, 100),
      NEW.conversation_id,
      NEW.id,
      NULL,
      jsonb_build_object('sender_id', NEW.sender_id)
    );
  END LOOP;
  
  -- Mettre à jour la conversation
  UPDATE conversations
  SET last_message_at = NEW.created_at,
      last_message_preview = LEFT(NEW.content, 100),
      updated_at = NEW.created_at
  WHERE id = NEW.conversation_id;
  
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trigger_notify_new_message ON messages;
CREATE TRIGGER trigger_notify_new_message
  AFTER INSERT ON messages
  FOR EACH ROW
  EXECUTE FUNCTION notify_new_message();

-- Fonction pour obtenir les conversations avec détails
CREATE OR REPLACE FUNCTION get_user_conversations(p_user_id UUID)
RETURNS TABLE (
  id UUID,
  name TEXT,
  type TEXT,
  creator_id UUID,
  last_message_at TIMESTAMP WITH TIME ZONE,
  last_message_preview TEXT,
  unread_count BIGINT,
  participants JSONB,
  created_at TIMESTAMP WITH TIME ZONE
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    c.id,
    c.name,
    c.type,
    c.creator_id,
    c.last_message_at,
    c.last_message_preview,
    (SELECT COUNT(*) FROM messages m 
     WHERE m.conversation_id = c.id 
       AND m.sender_id != p_user_id 
       AND m.status != 'read') as unread_count,
    (SELECT jsonb_agg(
      jsonb_build_object(
        'user_id', cp.user_id,
        'first_name', p.first_name,
        'last_name', p.last_name,
        'email', p.email,
        'avatar_url', p.avatar_url
      )
    ) FROM conversation_participants cp
    LEFT JOIN profiles p ON p.id = cp.user_id
    WHERE cp.conversation_id = c.id) as participants,
    c.created_at
  FROM conversations c
  WHERE EXISTS (
    SELECT 1 FROM conversation_participants cp
    WHERE cp.conversation_id = c.id AND cp.user_id = p_user_id
  )
  ORDER BY COALESCE(c.last_message_at, c.created_at) DESC;
END;
$$;