-- ============================================================================
-- AGENTS DE RESTAURANT — fondation + sécurité (calqué sur le système agent vendeur).
--
-- Le restaurateur (propriétaire d'un professional_services type restaurant) peut créer
-- des AGENTS (compte auth réel) et leur accorder des permissions PAR MODULE
-- (manage_orders, access_pos, manage_menu, manage_tables, manage_reservations,
--  manage_promotions, view_analytics, manage_media…).
--
-- Sécurité (modèle vendeur) : le RLS donne à l'agent ACTIF le même accès aux données du
-- restaurant que le propriétaire ; la granularité PAR MODULE est appliquée côté UI (onglets
-- filtrés) + backend (endpoints vérifient la permission). Phase 1 = données + RLS.
-- ============================================================================

-- 1) Table des agents de restaurant.
CREATE TABLE IF NOT EXISTS public.restaurant_agents (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id   uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  user_id                   uuid REFERENCES auth.users(id) ON DELETE CASCADE,  -- compte auth de l'agent
  name                      text NOT NULL,
  email                     text,
  phone                     text,
  agent_code                text,
  access_token              uuid DEFAULT gen_random_uuid(),
  permissions               jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_active                 boolean NOT NULL DEFAULT true,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),
  UNIQUE (professional_service_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_restaurant_agents_service ON public.restaurant_agents(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_restaurant_agents_user ON public.restaurant_agents(user_id) WHERE user_id IS NOT NULL;

-- 2) Fonction d'autorisation : propriétaire du service OU agent actif rattaché.
--    SECURITY DEFINER pour contourner le RLS lors de la vérification (pas de récursion).
CREATE OR REPLACE FUNCTION public.is_service_owner_or_agent(p_service_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT
    EXISTS (SELECT 1 FROM public.professional_services ps
            WHERE ps.id = p_service_id AND ps.user_id = auth.uid())
    OR
    EXISTS (SELECT 1 FROM public.restaurant_agents ra
            WHERE ra.professional_service_id = p_service_id
              AND ra.user_id = auth.uid() AND ra.is_active = true);
$$;
REVOKE ALL ON FUNCTION public.is_service_owner_or_agent(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_service_owner_or_agent(uuid) TO authenticated, service_role;

-- Vérifie une permission précise d'un agent (utilisé par le backend pour la granularité par module).
CREATE OR REPLACE FUNCTION public.service_agent_has_permission(p_service_id uuid, p_permission text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT
    -- Le propriétaire a toutes les permissions.
    EXISTS (SELECT 1 FROM public.professional_services ps
            WHERE ps.id = p_service_id AND ps.user_id = auth.uid())
    OR
    EXISTS (SELECT 1 FROM public.restaurant_agents ra
            WHERE ra.professional_service_id = p_service_id
              AND ra.user_id = auth.uid() AND ra.is_active = true
              AND COALESCE((ra.permissions ->> p_permission)::boolean, false) = true);
$$;
REVOKE ALL ON FUNCTION public.service_agent_has_permission(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.service_agent_has_permission(uuid, text) TO authenticated, service_role;

-- 3) RLS sur restaurant_agents : le restaurateur gère SES agents ; l'agent lit SA ligne.
ALTER TABLE public.restaurant_agents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS restaurant_agents_owner_manage ON public.restaurant_agents;
CREATE POLICY restaurant_agents_owner_manage ON public.restaurant_agents
  FOR ALL
  USING (EXISTS (SELECT 1 FROM public.professional_services ps WHERE ps.id = professional_service_id AND ps.user_id = auth.uid()))
  WITH CHECK (EXISTS (SELECT 1 FROM public.professional_services ps WHERE ps.id = professional_service_id AND ps.user_id = auth.uid()));

DROP POLICY IF EXISTS restaurant_agents_self_read ON public.restaurant_agents;
CREATE POLICY restaurant_agents_self_read ON public.restaurant_agents
  FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS restaurant_agents_service_role ON public.restaurant_agents;
CREATE POLICY restaurant_agents_service_role ON public.restaurant_agents
  FOR ALL TO service_role USING (true) WITH CHECK (true);

-- 4) Accès agent (additif) aux tables opérationnelles du restaurant : même portée que le propriétaire.
--    Policies OR'd avec l'existant → n'enlève aucun droit, ajoute l'agent actif.
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'restaurant_orders', 'restaurant_menu_items', 'restaurant_menu_categories',
    'restaurant_tables', 'restaurant_reservations', 'restaurant_promotions', 'service_gallery_images'
  ] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', t || '_agent_access', t);
    EXECUTE format(
      'CREATE POLICY %I ON public.%I FOR ALL USING (public.is_service_owner_or_agent(professional_service_id)) WITH CHECK (public.is_service_owner_or_agent(professional_service_id))',
      t || '_agent_access', t);
  END LOOP;
END $$;

SELECT 'Agents restaurant : table restaurant_agents + is_service_owner_or_agent + service_agent_has_permission + policies agent (7 tables).' AS status;
