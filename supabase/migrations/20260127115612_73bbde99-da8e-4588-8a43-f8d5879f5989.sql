-- Supprimer les anciennes politiques défaillantes
DROP POLICY IF EXISTS "Users can manage own addresses" ON public.user_addresses;
DROP POLICY IF EXISTS "Users can view own addresses" ON public.user_addresses;

-- Créer les bonnes politiques RLS basées sur auth.uid()
CREATE POLICY "Users can view own addresses" 
ON public.user_addresses 
FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own addresses" 
ON public.user_addresses 
FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own addresses" 
ON public.user_addresses 
FOR UPDATE 
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own addresses" 
ON public.user_addresses 
FOR DELETE 
USING (auth.uid() = user_id);