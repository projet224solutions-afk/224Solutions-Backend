-- Table des permissions des agents
CREATE TABLE IF NOT EXISTS public.agent_permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id uuid REFERENCES public.agents_management(id) ON DELETE CASCADE NOT NULL,
  permission_key text NOT NULL,
  permission_value boolean DEFAULT false,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE(agent_id, permission_key)
);

-- Index pour performance
CREATE INDEX IF NOT EXISTS idx_agent_permissions_agent_id ON public.agent_permissions(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_permissions_key ON public.agent_permissions(permission_key);

-- Enable RLS
ALTER TABLE public.agent_permissions ENABLE ROW LEVEL SECURITY;

-- Politique RLS: PDG peut voir/gérer les permissions de ses agents
CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM public.agents_management am
      INNER JOIN public.pdg_management pm ON am.pdg_id = pm.id
      WHERE am.id = agent_permissions.agent_id
      AND pm.user_id = auth.uid()
      AND pm.is_active = true
    )
  );

-- Politique RLS: Agent peut voir ses propres permissions
CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.agents_management am
      WHERE am.id = agent_permissions.agent_id
      AND am.user_id = auth.uid()
      AND am.is_active = true
    )
  );

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION public.update_agent_permissions_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER trigger_update_agent_permissions_updated_at
  BEFORE UPDATE ON public.agent_permissions
  FOR EACH ROW
  EXECUTE FUNCTION public.update_agent_permissions_updated_at();

-- Fonction RPC pour vérifier une permission
CREATE OR REPLACE FUNCTION public.check_agent_permission(
  p_agent_id uuid,
  p_permission_key text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_has_permission boolean;
BEGIN
  SELECT COALESCE(permission_value, false) INTO v_has_permission
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id
  AND permission_key = p_permission_key;
  
  RETURN COALESCE(v_has_permission, false);
END;
$$;

-- Fonction RPC pour définir plusieurs permissions pour un agent
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
  v_pdg_id uuid;
  v_permission_key text;
  v_permission_value boolean;
BEGIN
  SELECT pdg_id INTO v_pdg_id
  FROM public.agents_management am
  WHERE am.id = p_agent_id
  AND EXISTS (
    SELECT 1 FROM public.pdg_management pm
    WHERE pm.id = am.pdg_id
    AND pm.user_id = auth.uid()
    AND pm.is_active = true
  );
  
  IF v_pdg_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Vous n''avez pas les permissions pour modifier cet agent'
    );
  END IF;
  
  FOR v_permission_key, v_permission_value IN 
    SELECT key, value::boolean 
    FROM jsonb_each_text(p_permissions)
  LOOP
    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value)
    VALUES (p_agent_id, v_permission_key, v_permission_value)
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = EXCLUDED.permission_value, updated_at = now();
  END LOOP;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Permissions mises à jour avec succès'
  );
END;
$$;

-- Fonction RPC pour obtenir toutes les permissions d'un agent
CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_permissions jsonb;
BEGIN
  SELECT jsonb_object_agg(permission_key, permission_value)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;
  
  RETURN COALESCE(v_permissions, '{}'::jsonb);
END;
$$;

-- Activer realtime sur agent_permissions uniquement
ALTER PUBLICATION supabase_realtime ADD TABLE public.agent_permissions;
ALTER TABLE public.agent_permissions REPLICA IDENTITY FULL;