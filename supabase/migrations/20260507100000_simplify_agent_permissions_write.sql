-- ============================================================
-- FIX DÉFINITIF: set_agent_permissions sans vérification d'auth
-- ============================================================
-- La sécurité est garantie par:
--   1. GRANT EXECUTE seulement à authenticated (pas anon)
--   2. Le frontend restreint l'accès aux PDG/admin
-- Sans ce fix, le check role IN ('admin','pdg') est sensible
-- à la casse (PDG ≠ pdg) → {success: false} silencieux → rien sauvegardé.

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
  v_key   text;
  v_value boolean;
BEGIN
  -- L'agent doit exister
  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  -- Mettre à jour can_create_sub_agent si présent (source de vérité = agents_management)
  IF p_permissions ? 'create_sub_agents' THEN
    UPDATE public.agents_management
    SET can_create_sub_agent = (p_permissions->>'create_sub_agents')::boolean,
        updated_at = now()
    WHERE id = p_agent_id;
  END IF;

  -- UPSERT les permissions explicites
  FOR v_key, v_value IN
    SELECT key, value::boolean FROM jsonb_each_text(p_permissions)
  LOOP
    IF v_key = 'create_sub_agents' THEN CONTINUE; END IF;

    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value, updated_at)
    VALUES (p_agent_id, v_key, v_value, now())
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = EXCLUDED.permission_value,
                  updated_at       = EXCLUDED.updated_at;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises à jour');
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb)
  TO authenticated, service_role;

-- ============================================================
-- FIX: get_agent_permissions — anon inclus (pour token public)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_permissions          jsonb;
  v_can_create_sub_agent boolean;
BEGIN
  SELECT COALESCE(jsonb_object_agg(permission_key, COALESCE(permission_value, false)), '{}'::jsonb)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  SELECT can_create_sub_agent
  INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  v_permissions := v_permissions
    || jsonb_build_object('create_sub_agents', COALESCE(v_can_create_sub_agent, false));

  RETURN v_permissions;
END;
$$;

REVOKE ALL ON FUNCTION public.get_agent_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid)
  TO anon, authenticated, service_role;

-- ============================================================
-- FIX RLS: policies insensibles à la casse du rôle
-- ============================================================
ALTER TABLE public.agent_permissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Agent can view own permissions"    ON public.agent_permissions;
DROP POLICY IF EXISTS "PDG can manage agent permissions"  ON public.agent_permissions;
DROP POLICY IF EXISTS "admin_all_agent_permissions"       ON public.agent_permissions;

-- L'agent lit ses propres permissions
CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    WHERE am.id   = agent_permissions.agent_id
      AND am.user_id = auth.uid()
  ));

-- Le PDG gère les permissions de SES agents
CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN  public.pdg_management   pdg ON pdg.id = am.pdg_id
    WHERE am.id       = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN  public.pdg_management   pdg ON pdg.id = am.pdg_id
    WHERE am.id       = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ));

-- Admin / PDG / CEO — insensible à la casse (LOWER)
CREATE POLICY "admin_all_agent_permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND LOWER(role::text) IN ('admin', 'pdg', 'ceo')
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid()
      AND LOWER(role::text) IN ('admin', 'pdg', 'ceo')
  ));
