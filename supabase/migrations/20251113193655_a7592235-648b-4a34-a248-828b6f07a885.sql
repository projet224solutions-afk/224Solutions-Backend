-- Fix RLS policies on wallets table to use new role system
-- Remove old policy that uses the obsolete profiles.role column

DROP POLICY IF EXISTS "Admins can view all wallets" ON public.wallets;

-- The existing policies using has_role() are correct and sufficient:
-- "PDG can manage all wallets" 
-- "PDG can view all wallets"
-- These already use has_role(auth.uid(), 'admin'::user_role)

-- Ensure admins have full access with proper role checking
CREATE POLICY "Admins full access to wallets"
ON public.wallets
FOR ALL
TO authenticated
USING (
  has_role(auth.uid(), 'admin')
)
WITH CHECK (
  has_role(auth.uid(), 'admin')
);