-- ============================================================
-- FIX COMPLET: Permissions agents (lecture + écriture)
-- ============================================================
-- Problèmes corrigés:
-- 1. get_agent_permissions: SET row_security = off + GRANT à authenticated/anon
-- 2. set_agent_permissions: SET row_security = off + auth simplifiée (pdg_management OU rôle pdg/admin/ceo)
-- 3. RLS policies: idempotent DROP IF EXISTS + CREATE POLICY correctes
-- Ce script est idempotent (sûr à exécuter plusieurs fois)

-- ============================================================
-- 1. get_agent_permissions
-- ============================================================
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
  SELECT COALESCE(jsonb_object_agg(permission_key, COALESCE(permission_value, false)), '{}'::jsonb)
  INTO v_permissions
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  SELECT can_create_sub_agent
  INTO v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  v_permissions := v_permissions || jsonb_build_object(
    'create_sub_agents', COALESCE(v_can_create_sub_agent, false)
  );

  RETURN v_permissions;
END;
$$;

REVOKE ALL ON FUNCTION public.get_agent_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid) TO anon, authenticated, service_role;

-- ============================================================
-- 2. set_agent_permissions
-- ============================================================
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
  v_key text;
  v_value boolean;
  v_caller_uid uuid;
BEGIN
  v_caller_uid := auth.uid();

  -- L'agent doit exister
  IF NOT EXISTS (SELECT 1 FROM public.agents_management WHERE id = p_agent_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Agent introuvable');
  END IF;

  -- Vérification d'autorisation:
  -- a) Le PDG propriétaire de l'agent
  -- b) OU un utilisateur avec rôle admin/pdg/ceo dans profiles
  -- c) OU service_role (pas de auth.uid())
  IF v_caller_uid IS NOT NULL THEN
    IF NOT EXISTS (
      -- Propriétaire via pdg_management
      SELECT 1 FROM public.agents_management am
      JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
      WHERE am.id = p_agent_id AND pdg.user_id = v_caller_uid AND pdg.is_active = true
    ) AND NOT EXISTS (
      -- Rôle admin/pdg/ceo dans profiles
      SELECT 1 FROM public.profiles
      WHERE id = v_caller_uid AND role IN ('admin', 'pdg', 'ceo')
    ) THEN
      RETURN jsonb_build_object(
        'success', false,
        'error', 'Vous n''avez pas les droits pour modifier les permissions de cet agent'
      );
    END IF;
  END IF;

  -- Mettre à jour can_create_sub_agent si présent (source de vérité = agents_management)
  IF p_permissions ? 'create_sub_agents' THEN
    UPDATE public.agents_management
    SET can_create_sub_agent = (p_permissions->>'create_sub_agents')::boolean,
        updated_at = now()
    WHERE id = p_agent_id;
  END IF;

  -- UPSERT les autres permissions
  FOR v_key, v_value IN
    SELECT key, value::boolean FROM jsonb_each_text(p_permissions)
  LOOP
    IF v_key = 'create_sub_agents' THEN
      CONTINUE;
    END IF;

    INSERT INTO public.agent_permissions (agent_id, permission_key, permission_value, updated_at)
    VALUES (p_agent_id, v_key, v_value, now())
    ON CONFLICT (agent_id, permission_key)
    DO UPDATE SET permission_value = EXCLUDED.permission_value, updated_at = now();
  END LOOP;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises à jour avec succès');
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb) TO authenticated, service_role;

-- ============================================================
-- 3. check_agent_permission (utilisé par le backend)
-- ============================================================
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
  v_has_permission boolean := false;
BEGIN
  -- Table principale agent_permissions
  SELECT COALESCE(permission_value, false)
  INTO v_has_permission
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id
    AND permission_key = p_permission_key;

  IF COALESCE(v_has_permission, false) THEN
    RETURN true;
  END IF;

  -- Table des permissions déléguées PDG (si elle existe)
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='pdg_access_permissions') THEN
    SELECT EXISTS(
      SELECT 1 FROM public.pdg_access_permissions
      WHERE agent_id = p_agent_id
        AND permission_key = p_permission_key
        AND is_active = true
        AND (expires_at IS NULL OR expires_at > NOW())
    ) INTO v_has_permission;
  END IF;

  RETURN COALESCE(v_has_permission, false);
END;
$$;

REVOKE ALL ON FUNCTION public.check_agent_permission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_agent_permission(uuid, text) TO authenticated, service_role;

-- ============================================================
-- 4. RLS sur agent_permissions (idempotent)
-- ============================================================

-- S'assurer que RLS est activé
ALTER TABLE public.agent_permissions ENABLE ROW LEVEL SECURITY;

-- Supprimer et recréer les policies
DROP POLICY IF EXISTS "Agent can view own permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "PDG can manage agent permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "Agents can view own permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "PDGs can manage agent permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "service_role_all_agent_permissions" ON public.agent_permissions;
DROP POLICY IF EXISTS "admin_all_agent_permissions" ON public.agent_permissions;

-- L'agent peut lire ses propres permissions
CREATE POLICY "Agent can view own permissions" ON public.agent_permissions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    WHERE am.id = agent_permissions.agent_id
      AND am.user_id = auth.uid()
  ));

-- Le PDG peut gérer les permissions de ses agents
CREATE POLICY "PDG can manage agent permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ));

-- Admin/PDG/CEO peuvent tout voir et modifier
CREATE POLICY "admin_all_agent_permissions" ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo')
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND role IN ('admin', 'pdg', 'ceo')
  ));
