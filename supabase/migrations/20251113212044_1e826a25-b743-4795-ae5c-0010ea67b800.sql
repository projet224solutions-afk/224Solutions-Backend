-- Fonction RPC pour supprimer définitivement un agent (seulement par le PDG propriétaire)
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
  
  -- Supprimer définitivement l'agent
  DELETE FROM public.agents_management
  WHERE id = p_agent_id AND pdg_id = v_pdg_id;
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Agent supprimé définitivement',
    'agent_id', p_agent_id
  );
END;
$$;