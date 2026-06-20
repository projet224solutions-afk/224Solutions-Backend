-- Fix Security Definer Functions - Corrected for user_role enum

-- 1. Convert role check functions to SECURITY INVOKER
DROP FUNCTION IF EXISTS public.is_admin(uuid);
CREATE OR REPLACE FUNCTION public.is_admin(_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY INVOKER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = _user_id 
    AND role IN ('ceo', 'admin')
  );
$$;

-- 2. Add strict validation to critical SECURITY DEFINER functions
CREATE OR REPLACE FUNCTION public.agent_can_create_sub_agents(_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF _user_id IS NULL THEN
    RETURN false;
  END IF;
  
  RETURN EXISTS (
    SELECT 1
    FROM public.agents_management
    WHERE user_id = _user_id
      AND is_active = true
      AND (can_create_sub_agent = true OR permissions @> '["create_sub_agents"]'::jsonb)
  );
END;
$$;

-- 3. Revoke public execute on sensitive functions
REVOKE EXECUTE ON FUNCTION public.agent_can_create_sub_agents(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.agent_can_create_sub_agents(uuid) TO authenticated;

-- 4. Document remaining SECURITY DEFINER functions
COMMENT ON FUNCTION public.auto_create_user_wallet() IS 
'SECURITY DEFINER: Required for automatic wallet creation. Validated by auth trigger.';

COMMENT ON FUNCTION public.auto_create_agent_wallet() IS 
'SECURITY DEFINER: Required for automatic agent wallet creation.';

COMMENT ON FUNCTION public.acquire_taxi_lock(text, uuid, text, integer) IS 
'SECURITY DEFINER: Required for distributed lock management.';