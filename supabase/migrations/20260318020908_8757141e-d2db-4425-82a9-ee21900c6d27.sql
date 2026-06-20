-- Allow vendor agents to view their associated vendor
DROP POLICY IF EXISTS "Owners can always view their own vendor" ON public.vendors;
CREATE POLICY "Owners can always view their own vendor" ON public.vendors
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR public.is_vendor_agent_of(id)
  );
