-- Fonction RPC pour supprimer/désactiver un agent (seulement par le PDG propriétaire)
CREATE OR REPLACE FUNCTION public.delete_agent(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pdg_id uuid;
  v_agent_record record;
BEGIN
  -- Vérifier que l'utilisateur est un PDG
  SELECT id INTO v_pdg_id
  FROM public.pdg_management
  WHERE user_id = auth.uid() AND is_active = true;
  
  IF v_pdg_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Vous devez être un PDG pour effectuer cette action'
    );
  END IF;
  
  -- Vérifier que l'agent appartient à ce PDG
  SELECT * INTO v_agent_record
  FROM public.agents_management
  WHERE id = p_agent_id AND pdg_id = v_pdg_id;
  
  IF v_agent_record IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Agent non trouvé ou vous n''avez pas les permissions'
    );
  END IF;
  
  -- Désactiver l'agent
  UPDATE public.agents_management
  SET is_active = false, updated_at = now()
  WHERE id = p_agent_id AND pdg_id = v_pdg_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Agent désactivé avec succès',
    'agent_id', p_agent_id
  );
END;
$$;

-- Fonction RPC pour activer/désactiver un agent
CREATE OR REPLACE FUNCTION public.toggle_agent_status(p_agent_id uuid, p_is_active boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pdg_id uuid;
  v_agent_record record;
BEGIN
  -- Vérifier que l'utilisateur est un PDG
  SELECT id INTO v_pdg_id
  FROM public.pdg_management
  WHERE user_id = auth.uid() AND is_active = true;
  
  IF v_pdg_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Vous devez être un PDG pour effectuer cette action'
    );
  END IF;
  
  -- Vérifier que l'agent appartient à ce PDG
  SELECT * INTO v_agent_record
  FROM public.agents_management
  WHERE id = p_agent_id AND pdg_id = v_pdg_id;
  
  IF v_agent_record IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Agent non trouvé ou vous n''avez pas les permissions'
    );
  END IF;
  
  -- Mettre à jour le statut
  UPDATE public.agents_management
  SET is_active = p_is_active, updated_at = now()
  WHERE id = p_agent_id AND pdg_id = v_pdg_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', CASE WHEN p_is_active THEN 'Agent activé avec succès' ELSE 'Agent suspendu avec succès' END,
    'agent_id', p_agent_id,
    'is_active', p_is_active
  );
END;
$$;

-- Fonction RPC pour mettre à jour un agent
CREATE OR REPLACE FUNCTION public.update_agent(
  p_agent_id uuid,
  p_name text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_permissions jsonb DEFAULT NULL,
  p_commission_rate numeric DEFAULT NULL,
  p_can_create_sub_agent boolean DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pdg_id uuid;
  v_agent_record record;
BEGIN
  -- Vérifier que l'utilisateur est un PDG
  SELECT id INTO v_pdg_id
  FROM public.pdg_management
  WHERE user_id = auth.uid() AND is_active = true;
  
  IF v_pdg_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Vous devez être un PDG pour effectuer cette action'
    );
  END IF;
  
  -- Vérifier que l'agent appartient à ce PDG
  SELECT * INTO v_agent_record
  FROM public.agents_management
  WHERE id = p_agent_id AND pdg_id = v_pdg_id;
  
  IF v_agent_record IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Agent non trouvé ou vous n''avez pas les permissions'
    );
  END IF;
  
  -- Mettre à jour l'agent (seulement les champs fournis)
  UPDATE public.agents_management
  SET 
    name = COALESCE(p_name, name),
    email = COALESCE(p_email, email),
    phone = COALESCE(p_phone, phone),
    permissions = COALESCE(p_permissions, permissions),
    commission_rate = COALESCE(p_commission_rate, commission_rate),
    can_create_sub_agent = COALESCE(p_can_create_sub_agent, can_create_sub_agent),
    updated_at = now()
  WHERE id = p_agent_id AND pdg_id = v_pdg_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Agent mis à jour avec succès',
    'agent_id', p_agent_id
  );
END;
$$;