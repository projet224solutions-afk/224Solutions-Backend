-- Ajouter recipient_id à la table messages pour simplifier les requêtes
ALTER TABLE messages 
ADD COLUMN IF NOT EXISTS recipient_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

-- Index pour améliorer les performances des requêtes
CREATE INDEX IF NOT EXISTS idx_messages_recipient ON messages(recipient_id);
CREATE INDEX IF NOT EXISTS idx_messages_sender_recipient ON messages(sender_id, recipient_id);

-- Mettre à jour les messages existants pour remplir recipient_id depuis conversation_participants
UPDATE messages m
SET recipient_id = (
  SELECT cp.user_id
  FROM conversation_participants cp
  WHERE cp.conversation_id = m.conversation_id
    AND cp.user_id != m.sender_id
  LIMIT 1
)
WHERE recipient_id IS NULL;

-- Politique RLS simplifiée pour les messages
DROP POLICY IF EXISTS "Users can view their messages" ON messages;
CREATE POLICY "Users can view their messages" ON messages
  FOR SELECT
  USING (
    auth.uid() = sender_id 
    OR auth.uid() = recipient_id
    OR auth.uid() IN (
      SELECT user_id FROM conversation_participants 
      WHERE conversation_id = messages.conversation_id
    )
  );

DROP POLICY IF EXISTS "Users can insert messages" ON messages;
CREATE POLICY "Users can insert messages" ON messages
  FOR INSERT
  WITH CHECK (
    auth.uid() = sender_id
    AND (
      recipient_id IS NOT NULL
      OR auth.uid() IN (
        SELECT user_id FROM conversation_participants 
        WHERE conversation_id = messages.conversation_id
      )
    )
  );

DROP POLICY IF EXISTS "Users can update their messages" ON messages;
CREATE POLICY "Users can update their messages" ON messages
  FOR UPDATE
  USING (auth.uid() = sender_id);

DROP POLICY IF EXISTS "Users can delete their messages" ON messages;
CREATE POLICY "Users can delete their messages" ON messages
  FOR DELETE
  USING (auth.uid() = sender_id);

-- Activer RLS si ce n'est pas déjà fait
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
