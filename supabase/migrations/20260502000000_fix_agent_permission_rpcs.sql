-- ============================================================
-- FIX: check_agent_permission — check both tables
-- ============================================================
-- PROBLÈME 1: check_agent_permission ne lisait que agent_permissions.
-- pdg_access_permissions (permissions déléguées via grant_pdg_permission_to_agent)
-- était ignoré → permissions PDG déléguées jamais appliquées côté backend.
--
-- PROBLÈME 2: Ni check_agent_permission ni get_agent_permissions ni
-- set_agent_permissions n'avaient SET row_security = off, laissant la
-- décision de bypass RLS implicite (dépend du owner de la fonction).
--
-- FIX: Toutes les fonctions ont maintenant row_security = off explicit.
-- check_agent_permission vérifie les deux tables (OR logique).

CREATE OR REPLACE FUNCTION public.check_agent_permission(
  p_agent_id uuid,
  p_permission_key text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_has_permission boolean;
BEGIN
  -- Chercher dans agent_permissions (table principale, UPSERT via set_agent_permissions)
  SELECT COALESCE(permission_value, false)
  INTO v_has_permission
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id
    AND permission_key = p_permission_key;

  IF COALESCE(v_has_permission, false) THEN
    RETURN true;
  END IF;

  -- Chercher dans pdg_access_permissions (permissions déléguées par le PDG)
  SELECT EXISTS(
    SELECT 1
    FROM public.pdg_access_permissions
    WHERE agent_id = p_agent_id
      AND permission_key = p_permission_key
      AND is_active = true
      AND (expires_at IS NULL OR expires_at > NOW())
  ) INTO v_has_permission;

  RETURN COALESCE(v_has_permission, false);
END;
$$;

REVOKE ALL ON FUNCTION public.check_agent_permission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_agent_permission(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.check_agent_permission(uuid, text) TO authenticated;

-- ============================================================
-- FIX: get_agent_permissions — row_security = off + can_create_sub_agent
-- ============================================================
-- NOTE: La migration 20251225 avait ajouté la fusion de can_create_sub_agent
-- depuis agents_management. Cette version préserve cette logique + ajoute
-- row_security = off.

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
  SELECT jsonb_object_agg(permission_key, permission_value)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  -- Fusionner can_create_sub_agent depuis agents_management (source de vérité)
  SELECT can_create_sub_agent
  INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  v_permissions := COALESCE(v_permissions, '{}'::jsonb);
  v_permissions := v_permissions || jsonb_build_object('create_sub_agents', COALESCE(v_can_create_sub_agent, false));

  RETURN v_permissions;
END;
$$;

REVOKE ALL ON FUNCTION public.get_agent_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO anon;

-- ============================================================
-- FIX: set_agent_permissions — row_security = off + can_create_sub_agent + admin auth
-- ============================================================
-- NOTE: Conserve la sémantique UPSERT (pas de DELETE avant INSERT).
-- Préserve la logique can_create_sub_agent de la migration 20251225.
-- Ajoute l'autorisation pour les admins (pas seulement PDG propriétaire).

CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_pdg_id uuid;
  v_permission_key text;
  v_permission_value boolean;
  v_create_sub_agents boolean;
BEGIN
  -- Vérifier que le PDG appelant a le droit de modifier cet agent
  SELECT pdg_id INTO v_pdg_id
  FROM public.agents_management am
  WHERE am.id = p_agent_id
    AND EXISTS (
      SELECT 1 FROM public.pdg_management pm
      WHERE pm.id = am.pdg_id
        AND pm.user_id = auth.uid()
        AND pm.is_active = true
    );

  -- Permettre aussi aux admins/pdg génériques
  IF v_pdg_id IS NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.profiles
      WHERE id = auth.uid()
        AND role IN ('admin', 'pdg')
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Vous n''avez pas les permissions pour modifier cet agent'
      );
    END IF;
  END IF;

  -- Vérifier que l'agent existe
  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  -- Extraire et mettre à jour can_create_sub_agent si présent (source de vérité = agents_management)
  IF p_permissions ? 'create_sub_agents' THEN
    v_create_sub_agents := (p_permissions->>'create_sub_agents')::boolean;
    UPDATE public.agents_management
    SET can_create_sub_agent = v_create_sub_agents, updated_at = now()
    WHERE id = p_agent_id;
  END IF;

  -- UPSERT les autres permissions dans agent_permissions
  FOR v_permission_key, v_permission_value IN
    SELECT key, value::boolean FROM jsonb_each_text(p_permissions)
  LOOP
    -- create_sub_agents est géré dans agents_management, pas dans agent_permissions
    IF v_permission_key = 'create_sub_agents' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value, updated_at)
    VALUES (p_agent_id, v_permission_key, v_permission_value, now())
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = EXCLUDED.permission_value, updated_at = now();
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Permissions mises à jour avec succès'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO authenticated;
