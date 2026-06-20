-- Ajouter des policies pour permettre les messages directs sans conversation_id
-- Ces policies permettent la messagerie peer-to-peer simple

-- Policy pour permettre l'insertion de messages directs (sans conversation_id)
CREATE POLICY "Users can send direct messages"
ON public.messages
FOR INSERT
WITH CHECK (
  auth.uid() = sender_id 
  AND conversation_id IS NULL
);

-- Policy pour permettre la lecture de messages directs (sans conversation_id)
CREATE POLICY "Users can view direct messages"
ON public.messages
FOR SELECT
USING (
  (auth.uid() = sender_id OR auth.uid() = recipient_id)
  AND conversation_id IS NULL
);

-- Policy pour permettre la mise à jour de messages directs (marquage comme lu)
CREATE POLICY "Users can update their received direct messages"
ON public.messages
FOR UPDATE
USING (
  auth.uid() = recipient_id
  AND conversation_id IS NULL
);