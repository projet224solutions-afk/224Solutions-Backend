-- Fix RLS: allow authenticated users to insert their own interactions
CREATE POLICY "Users can insert own interactions"
ON public.user_product_interactions
FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

-- Allow users to read their own interactions
CREATE POLICY "Users can read own interactions"
ON public.user_product_interactions
FOR SELECT
TO authenticated
USING (auth.uid() = user_id);

-- Allow anon to read popularity scores (already exists but ensure)
-- Allow anon to read co-purchases (already exists but ensure)
