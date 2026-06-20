-- Mettre à jour la fonction get_agent_permissions pour inclure can_create_sub_agent
CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_permissions jsonb;
  v_can_create_sub_agent boolean;
BEGIN
  -- Récupérer les permissions de la table agent_permissions
  SELECT jsonb_object_agg(permission_key, permission_value)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;
  
  -- Récupérer la valeur de can_create_sub_agent depuis agents_management
  SELECT can_create_sub_agent
  INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;
  
  -- Fusionner avec create_sub_agents
  v_permissions := COALESCE(v_permissions, '{}'::jsonb);
  v_permissions := v_permissions || jsonb_build_object('create_sub_agents', COALESCE(v_can_create_sub_agent, false));
  
  RETURN v_permissions;
END;
$$;

-- Mettre à jour la fonction set_agent_permissions pour gérer can_create_sub_agent
CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text;
  v_value boolean;
  v_create_sub_agents boolean;
BEGIN
  -- Vérifier que l'agent existe
  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  -- Extraire et mettre à jour can_create_sub_agent si présent
  IF p_permissions ? 'create_sub_agents' THEN
    v_create_sub_agents := (p_permissions->>'create_sub_agents')::boolean;
    
    UPDATE public.agents_management
    SET can_create_sub_agent = v_create_sub_agents,
        updated_at = now()
    WHERE id = p_agent_id;
  END IF;

  -- Parcourir les permissions et les upsert (sauf create_sub_agents qui est dans agents_management)
  FOR v_key, v_value IN SELECT * FROM jsonb_each_text(p_permissions)
  LOOP
    -- Ignorer create_sub_agents car géré séparément
    IF v_key = 'create_sub_agents' THEN
      CONTINUE;
    END IF;
    
    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value, updated_at)
    VALUES (p_agent_id, v_key, v_value::boolean, now())
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = v_value::boolean, updated_at = now();
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises à jour avec succès');
END;
$$;