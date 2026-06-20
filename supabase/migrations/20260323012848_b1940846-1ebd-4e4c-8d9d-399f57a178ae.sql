CREATE POLICY "PDG can view all subscriptions"
ON public.subscriptions
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM pdg_management WHERE pdg_management.user_id = auth.uid()
  )
);