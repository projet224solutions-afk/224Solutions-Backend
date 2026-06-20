-- Supprimer TOUTES les policies existantes pour conversations, messages et conversation_participants
DO $$
DECLARE
  r RECORD;
BEGIN
  -- Supprimer toutes les policies pour conversations
  FOR r IN (SELECT policyname FROM pg_policies WHERE tablename = 'conversations' AND schemaname = 'public')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON conversations', r.policyname);
  END LOOP;
  
  -- Supprimer toutes les policies pour conversation_participants
  FOR r IN (SELECT policyname FROM pg_policies WHERE tablename = 'conversation_participants' AND schemaname = 'public')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON conversation_participants', r.policyname);
  END LOOP;
  
  -- Supprimer toutes les policies pour messages
  FOR r IN (SELECT policyname FROM pg_policies WHERE tablename = 'messages' AND schemaname = 'public')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON messages', r.policyname);
  END LOOP;
END $$;

-- Recréer les policies CORRECTEMENT sans récursion

-- CONVERSATIONS
CREATE POLICY "conv_select_policy"
  ON conversations FOR SELECT
  USING (
    creator_id = auth.uid()
    OR id IN (
      SELECT conversation_id FROM conversation_participants WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "conv_insert_policy"
  ON conversations FOR INSERT
  WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "conv_update_policy"
  ON conversations FOR UPDATE
  USING (auth.uid() = creator_id);

CREATE POLICY "conv_service_role_policy"
  ON conversations FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- CONVERSATION_PARTICIPANTS
CREATE POLICY "cp_select_policy"
  ON conversation_participants FOR SELECT
  USING (
    user_id = auth.uid()
    OR conversation_id IN (
      SELECT id FROM conversations WHERE creator_id = auth.uid()
    )
  );

CREATE POLICY "cp_insert_policy"
  ON conversation_participants FOR INSERT
  WITH CHECK (
    conversation_id IN (
      SELECT id FROM conversations WHERE creator_id = auth.uid()
    )
  );

CREATE POLICY "cp_service_role_policy"
  ON conversation_participants FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- MESSAGES
CREATE POLICY "msg_select_policy"
  ON messages FOR SELECT
  USING (
    sender_id = auth.uid()
    OR recipient_id = auth.uid()
    OR conversation_id IN (
      SELECT conversation_id FROM conversation_participants WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "msg_insert_policy"
  ON messages FOR INSERT
  WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "msg_update_policy"
  ON messages FOR UPDATE
  USING (auth.uid() = sender_id);

CREATE POLICY "msg_service_role_policy"
  ON messages FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');