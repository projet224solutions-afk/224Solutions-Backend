-- Supprimer la policy récursive
DROP POLICY IF EXISTS "users_view_conversation_participants" ON conversation_participants;

-- Créer une policy simple sans récursion
CREATE POLICY "users_view_own_conversation_participants" 
ON conversation_participants 
FOR SELECT 
USING (user_id = auth.uid());

-- Supprimer les policies redondantes/problématiques sur messages qui référencent conversation_participants
DROP POLICY IF EXISTS "Users can view their messages" ON messages;
DROP POLICY IF EXISTS "Users can view messages in their conversations" ON messages;
DROP POLICY IF EXISTS "Users can view direct messages" ON messages;