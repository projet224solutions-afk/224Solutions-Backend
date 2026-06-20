-- Fix: make get_agent_permissions reliably bypass RLS
-- This ensures agent dashboards (authenticated or token-based) always get the permission map.

CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_permissions jsonb;
  v_can_create_sub_agent boolean;
BEGIN
  -- Permissions depuis la table agent_permissions
  SELECT COALESCE(jsonb_object_agg(permission_key, COALESCE(permission_value, false)), '{}'::jsonb)
    INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  -- Flag legacy can_create_sub_agent (fusionné dans la map)
  SELECT can_create_sub_agent
    INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  v_permissions := v_permissions || jsonb_build_object('create_sub_agents', COALESCE(v_can_create_sub_agent, false));

  RETURN v_permissions;
END;
$$;

-- Ensure API roles can execute (in case privileges were reset)
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO anon, authenticated;