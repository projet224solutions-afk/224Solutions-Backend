-- Corriger la récursion infinie dans les politiques RLS de conversation_participants

-- Ajouter creator_id à la table conversations pour éviter la récursion
ALTER TABLE public.conversations 
ADD COLUMN IF NOT EXISTS creator_id UUID REFERENCES auth.users(id);

-- Supprimer les anciennes politiques qui causent la récursion
DROP POLICY IF EXISTS "Users can view participants of their conversations" ON public.conversation_participants;
DROP POLICY IF EXISTS "Users can add participants to their conversations" ON public.conversation_participants;

-- Nouvelles politiques sans récursion pour conversation_participants
CREATE POLICY "Users can view participants where they are creator"
ON public.conversation_participants
FOR SELECT
USING (
  EXISTS (
    SELECT 1 FROM public.conversations c
    WHERE c.id = conversation_participants.conversation_id
    AND c.creator_id = auth.uid()
  )
  OR user_id = auth.uid()
);

CREATE POLICY "Users can insert participants to their conversations"
ON public.conversation_participants
FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.conversations c
    WHERE c.id = conversation_id
    AND c.creator_id = auth.uid()
  )
);

-- Politique pour conversations
DROP POLICY IF EXISTS "Users can create conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can view their conversations" ON public.conversations;
DROP POLICY IF EXISTS "Users can update their conversations" ON public.conversations;

CREATE POLICY "Users can create conversations"
ON public.conversations
FOR INSERT
WITH CHECK (auth.uid() = creator_id);

CREATE POLICY "Users can view conversations where they are participants"
ON public.conversations
FOR SELECT
USING (
  creator_id = auth.uid()
  OR id IN (
    SELECT conversation_id 
    FROM public.conversation_participants 
    WHERE user_id = auth.uid()
  )
);

CREATE POLICY "Users can update their conversations"
ON public.conversations
FOR UPDATE
USING (creator_id = auth.uid());