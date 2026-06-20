
-- Create a function to delete storage objects by owner_id
CREATE OR REPLACE FUNCTION public.delete_user_storage_objects(target_user_id UUID)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM storage.objects WHERE owner_id = target_user_id;
END;
$$;
