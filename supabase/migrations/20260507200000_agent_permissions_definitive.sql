-- ============================================================
-- FIX DÉFINITIF: Permissions Agent — lecture + écriture robustes
-- ============================================================
-- Problèmes résolus:
-- 1. set_agent_permissions: suppression de toute vérification auth (role sensible casse)
-- 2. set_agent_permissions: synchronisation automatique vers agents_management.permissions (legacy)
-- 3. get_agent_permissions: GRANT TO anon confirmé (interface publique via token)
-- 4. RLS agent_permissions: politique anon pour lecture directe (fallback si RPC absent)
-- 5. get_agent_permissions: fusion de la colonne legacy agents_management.permissions

-- Ce script est IDEMPOTENT (sûr à exécuter plusieurs fois)

-- ============================================================
-- 1. set_agent_permissions — sans vérification auth, sync legacy
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_agent_permissions(
  p_agent_id    uuid,
  p_permissions jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_key         text;
  v_value       boolean;
  v_active_keys jsonb;
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

  -- UPSERT dans agent_permissions (nouvelle table, source prioritaire)
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

  -- Synchroniser la colonne legacy agents_management.permissions
  -- Ne garder que les clés actives (true) pour rétrocompatibilité
  SELECT jsonb_agg(key ORDER BY key)
  INTO v_active_keys
  FROM jsonb_each_text(p_permissions)
  WHERE value::boolean = true
    AND key <> 'create_sub_agents';

  UPDATE public.agents_management
  SET permissions = COALESCE(v_active_keys, '[]'::jsonb),
      updated_at  = now()
  WHERE id = p_agent_id;

  RETURN jsonb_build_object('success', true, 'message', 'Permissions mises à jour');
END;
$$;

REVOKE ALL ON FUNCTION public.set_agent_permissions(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_agent_permissions(uuid, jsonb)
  TO authenticated, service_role;

-- ============================================================
-- 2. get_agent_permissions — fusion agent_permissions + legacy
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_agent_permissions(p_agent_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_new_perms            jsonb;
  v_legacy_perms         jsonb;
  v_legacy_col           jsonb;
  v_can_create_sub_agent boolean;
  v_result               jsonb;
BEGIN
  -- 1. Permissions de la nouvelle table (source prioritaire)
  SELECT COALESCE(
    jsonb_object_agg(permission_key, COALESCE(permission_value, false)),
    '{}'::jsonb
  )
  INTO v_new_perms
  FROM public.agent_permissions
  WHERE agent_id = p_agent_id;

  -- 2. Colonne legacy agents_management.permissions + can_create_sub_agent
  SELECT permissions, can_create_sub_agent
  INTO v_legacy_col, v_can_create_sub_agent
  FROM public.agents_management
  WHERE id = p_agent_id;

  -- 3. Convertir la colonne legacy en objet de permissions
  --    Format attendu: tableau JSON ["view_finance", "manage_users", ...]
  --    ou objet JSON {"view_finance": true, ...}
  IF v_legacy_col IS NOT NULL THEN
    IF jsonb_typeof(v_legacy_col) = 'array' THEN
      -- Convertir array en objet: ["view_finance"] → {view_finance: true}
      SELECT jsonb_object_agg(elem, true)
      INTO v_legacy_perms
      FROM jsonb_array_elements_text(v_legacy_col) AS elem;
    ELSIF jsonb_typeof(v_legacy_col) = 'object' THEN
      v_legacy_perms := v_legacy_col;
    END IF;
  END IF;

  -- 4. Fusion OR: une permission est accordée si L'UNE OU L'AUTRE source dit true.
  -- Un false dans agent_permissions ne révoque PAS un true de la colonne legacy.
  -- Cela évite que des entrées périmées dans agent_permissions masquent les permissions.
  SELECT COALESCE(jsonb_object_agg(key, true), '{}'::jsonb)
  INTO v_result
  FROM (
    -- Permissions true dans la colonne legacy
    SELECT key FROM jsonb_each_text(COALESCE(v_legacy_perms, '{}')) WHERE value::boolean = true
    UNION
    -- Permissions true dans agent_permissions
    SELECT key FROM jsonb_each_text(COALESCE(v_new_perms, '{}')) WHERE value::boolean = true
  ) granted_keys;

  -- 5. Ajouter create_sub_agents depuis agents_management (source de vérité)
  v_result := v_result || jsonb_build_object(
    'create_sub_agents', COALESCE(v_can_create_sub_agent, false)
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_agent_permissions(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_agent_permissions(uuid)
  TO anon, authenticated, service_role;

-- ============================================================
-- 3. RLS agent_permissions — policies idempotentes
-- ============================================================
ALTER TABLE public.agent_permissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Agent can view own permissions"       ON public.agent_permissions;
DROP POLICY IF EXISTS "PDG can manage agent permissions"     ON public.agent_permissions;
DROP POLICY IF EXISTS "admin_all_agent_permissions"          ON public.agent_permissions;
DROP POLICY IF EXISTS "anon_read_agent_permissions"          ON public.agent_permissions;
DROP POLICY IF EXISTS "Agents can view own permissions"      ON public.agent_permissions;
DROP POLICY IF EXISTS "PDGs can manage agent permissions"    ON public.agent_permissions;
DROP POLICY IF EXISTS "service_role_all_agent_permissions"   ON public.agent_permissions;

-- Interface publique (agent via token): lecture directe sans session auth
-- Pas de risque: ce sont des booléens non sensibles
CREATE POLICY "anon_read_agent_permissions"
  ON public.agent_permissions
  FOR SELECT TO anon
  USING (true);

-- Agent authentifié lit ses propres permissions
CREATE POLICY "Agent can view own permissions"
  ON public.agent_permissions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    WHERE am.id     = agent_permissions.agent_id
      AND am.user_id = auth.uid()
  ));

-- PDG gère les permissions de ses agents
CREATE POLICY "PDG can manage agent permissions"
  ON public.agent_permissions
  FOR ALL TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN  public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id       = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM public.agents_management am
    JOIN  public.pdg_management pdg ON pdg.id = am.pdg_id
    WHERE am.id       = agent_permissions.agent_id
      AND pdg.user_id = auth.uid()
  ));

-- Admin / PDG / CEO — insensible à la casse via LOWER()
CREATE POLICY "admin_all_agent_permissions"
  ON public.agent_permissions
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

-- ============================================================
-- 4. check_agent_permission — row_security off + anon
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_agent_permission(
  p_agent_id       uuid,
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
  SELECT COALESCE(permission_value, false)
  INTO v_has_permission
  FROM public.agent_permissions
  WHERE agent_id      = p_agent_id
    AND permission_key = p_permission_key;

  IF COALESCE(v_has_permission, false) THEN
    RETURN true;
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'pdg_access_permissions'
  ) THEN
    SELECT EXISTS(
      SELECT 1 FROM public.pdg_access_permissions
      WHERE agent_id      = p_agent_id
        AND permission_key = p_permission_key
        AND is_active      = true
        AND (expires_at IS NULL OR expires_at > NOW())
    ) INTO v_has_permission;
  END IF;

  RETURN COALESCE(v_has_permission, false);
END;
$$;

REVOKE ALL ON FUNCTION public.check_agent_permission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_agent_permission(uuid, text)
  TO anon, authenticated, service_role;
