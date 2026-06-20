-- Allow vendor_agents to read their own record
CREATE POLICY "vendor_agents_self_select" 
ON public.vendor_agents 
FOR SELECT 
TO authenticated 
USING (user_id = auth.uid());