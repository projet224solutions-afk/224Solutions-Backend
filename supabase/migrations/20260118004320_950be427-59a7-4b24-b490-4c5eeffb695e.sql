-- Create a function to check if user is admin/pdg (security definer to bypass RLS)
CREATE OR REPLACE FUNCTION public.is_admin_or_pdg()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid()
      AND role::text IN ('admin', 'pdg')
  )
$$;

-- Add policy for admins/PDG to update any user_ids
CREATE POLICY "Admins can update all user_ids"
ON public.user_ids
FOR UPDATE
TO authenticated
USING (public.is_admin_or_pdg())
WITH CHECK (public.is_admin_or_pdg());

-- Add policy for admins/PDG to delete any user_ids (if needed)
CREATE POLICY "Admins can delete all user_ids"
ON public.user_ids
FOR DELETE
TO authenticated
USING (public.is_admin_or_pdg());