-- Supprimer les politiques existantes problématiques
DROP POLICY IF EXISTS "conv_select_policy" ON conversations;
DROP POLICY IF EXISTS "conv_insert_policy" ON conversations;
DROP POLICY IF EXISTS "conv_update_policy" ON conversations;
DROP POLICY IF EXISTS "conv_service_role_policy" ON conversations;

DROP POLICY IF EXISTS "cp_select_policy" ON conversation_participants;
DROP POLICY IF EXISTS "cp_insert_policy" ON conversation_participants;
DROP POLICY IF EXISTS "cp_service_role_policy" ON conversation_participants;

DROP POLICY IF EXISTS "msg_select_policy" ON messages;
DROP POLICY IF EXISTS "msg_insert_policy" ON messages;
DROP POLICY IF EXISTS "msg_update_policy" ON messages;
DROP POLICY IF EXISTS "msg_service_role_policy" ON messages;

-- Créer des fonctions security definer pour éviter la récursion

-- Fonction pour vérifier si un utilisateur est participant d'une conversation
CREATE OR REPLACE FUNCTION public.is_conversation_participant(
  _conversation_id uuid,
  _user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM conversation_participants
    WHERE conversation_id = _conversation_id
      AND user_id = _user_id
  )
$$;

-- Fonction pour vérifier si un utilisateur est créateur d'une conversation
CREATE OR REPLACE FUNCTION public.is_conversation_creator(
  _conversation_id uuid,
  _user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM conversations
    WHERE id = _conversation_id
      AND creator_id = _user_id
  )
$$;

-- Fonction pour vérifier si un utilisateur peut voir un message
CREATE OR REPLACE FUNCTION public.can_view_message(
  _message_id uuid,
  _user_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM messages m
    JOIN conversation_participants cp ON m.conversation_id = cp.conversation_id
    WHERE m.id = _message_id
      AND cp.user_id = _user_id
  )
$$;

-- Nouvelles politiques pour conversations utilisant les fonctions
CREATE POLICY "Users can view conversations they participate in"
  ON conversations
  FOR SELECT
  USING (
    auth.uid() = creator_id 
    OR public.is_conversation_participant(id, auth.uid())
  );

CREATE POLICY "Users can create conversations"
  ON conversations
  FOR INSERT
  WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Creators can update their conversations"
  ON conversations
  FOR UPDATE
  USING (auth.uid() = creator_id);

CREATE POLICY "Service role full access to conversations"
  ON conversations
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Nouvelles politiques pour conversation_participants utilisant les fonctions
CREATE POLICY "Users can view participants of their conversations"
  ON conversation_participants
  FOR SELECT
  USING (
    user_id = auth.uid()
    OR public.is_conversation_participant(conversation_id, auth.uid())
    OR public.is_conversation_creator(conversation_id, auth.uid())
  );

CREATE POLICY "Creators can add participants"
  ON conversation_participants
  FOR INSERT
  WITH CHECK (public.is_conversation_creator(conversation_id, auth.uid()));

CREATE POLICY "Service role full access to participants"
  ON conversation_participants
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');

-- Nouvelles politiques pour messages utilisant les fonctions
CREATE POLICY "Users can view messages in their conversations"
  ON messages
  FOR SELECT
  USING (public.is_conversation_participant(conversation_id, auth.uid()));

CREATE POLICY "Participants can send messages"
  ON messages
  FOR INSERT
  WITH CHECK (
    auth.uid() = sender_id
    AND public.is_conversation_participant(conversation_id, auth.uid())
  );

CREATE POLICY "Users can update their own messages"
  ON messages
  FOR UPDATE
  USING (
    auth.uid() = sender_id
    AND public.is_conversation_participant(conversation_id, auth.uid())
  );

CREATE POLICY "Service role full access to messages"
  ON messages
  FOR ALL
  USING (auth.role() = 'service_role')
  WITH CHECK (auth.role() = 'service_role');