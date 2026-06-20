-- CORRECTION COMPLÈTE DES RLS POLICIES POUR ÉVITER LA RÉCURSION INFINIE

-- 1. Supprimer toutes les policies existantes pour repartir proprement
DROP POLICY IF EXISTS "Users can view conversations where they are participants" ON conversations;
DROP POLICY IF EXISTS "Users can create conversations" ON conversations;
DROP POLICY IF EXISTS "Users can update their conversations" ON conversations;
DROP POLICY IF EXISTS "service_role_all_conversations" ON conversations;

DROP POLICY IF EXISTS "Users can view participants where they are creator" ON conversation_participants;
DROP POLICY IF EXISTS "Users can insert participants to their conversations" ON conversation_participants;
DROP POLICY IF EXISTS "service_role_all_participants" ON conversation_participants;

DROP POLICY IF EXISTS "Users can view their messages" ON messages;
DROP POLICY IF EXISTS "Users can send messages" ON messages;
DROP POLICY IF EXISTS "Users can send messages in their conversations" ON messages;
DROP POLICY IF EXISTS "Users can view messages in their conversations" ON messages;
DROP POLICY IF EXISTS "Users can update their messages" ON messages;
DROP POLICY IF EXISTS "service_role_all" ON messages;

-- 2. Recréer les policies SANS RÉCURSION pour conversations
CREATE POLICY "Users can view their conversations"
  ON conversations FOR SELECT
  USING (
    creator_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM conversation_participants cp
      WHERE cp.conversation_id = conversations.id
        AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can create conversations"
  ON conversations FOR INSERT
  WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Users can update conversations they created"
  ON conversations FOR UPDATE
  USING (auth.uid() = creator_id);

CREATE POLICY "service_role_full_access_conversations"
  ON conversations FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- 3. Policies pour conversation_participants
CREATE POLICY "Users can view participants in their conversations"
  ON conversation_participants FOR SELECT
  USING (
    user_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM conversations c
      WHERE c.id = conversation_participants.conversation_id
        AND c.creator_id = auth.uid()
    )
  );

CREATE POLICY "Users can add participants to conversations they created"
  ON conversation_participants FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM conversations c
      WHERE c.id = conversation_participants.conversation_id
        AND c.creator_id = auth.uid()
    )
  );

CREATE POLICY "service_role_full_access_participants"
  ON conversation_participants FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- 4. Policies pour messages
CREATE POLICY "Users can view messages in their conversations"
  ON messages FOR SELECT
  USING (
    sender_id = auth.uid()
    OR recipient_id = auth.uid()
    OR EXISTS (
      SELECT 1 FROM conversation_participants cp
      WHERE cp.conversation_id = messages.conversation_id
        AND cp.user_id = auth.uid()
    )
  );

CREATE POLICY "Users can send messages"
  ON messages FOR INSERT
  WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "Users can update their own messages"
  ON messages FOR UPDATE
  USING (auth.uid() = sender_id);

CREATE POLICY "service_role_full_access_messages"
  ON messages FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');