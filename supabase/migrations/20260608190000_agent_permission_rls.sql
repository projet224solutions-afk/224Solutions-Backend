-- ============================================================================
-- RLS conscient des permissions agent
-- ----------------------------------------------------------------------------
-- Objectif : un AGENT du PDG peut LIRE les données plateforme d'une section
-- UNIQUEMENT s'il a la permission correspondante (déléguée par le PDG).
--
-- Principe : politiques SELECT *additives* (PERMISSIVE) — elles n'enlèvent RIEN
-- aux politiques existantes (admin/pdg/propriétaire restent valides), elles
-- AJOUTENT un accès en lecture conditionné à la permission. Aucun accès en
-- écriture n'est accordé ici.
--
-- ⚠️ À appliquer manuellement (SQL editor). Non destructif (CREATE OR REPLACE /
--    DROP POLICY IF EXISTS + CREATE POLICY). Rejouable.
-- ============================================================================

-- 1) Fonction d'aide : l'utilisateur courant est-il un agent ACTIF possédant
--    la permission demandée ? (table agent_permissions + colonne legacy)
CREATE OR REPLACE FUNCTION public.current_agent_has_permission(p_permission text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    EXISTS (
      SELECT 1
      FROM public.agents_management am
      JOIN public.agent_permissions ap ON ap.agent_id = am.id
      WHERE am.user_id = auth.uid()
        AND am.is_active = true
        AND ap.permission_key = p_permission
        AND ap.permission_value = true
    )
    OR EXISTS (
      SELECT 1
      FROM public.agents_management am
      WHERE am.user_id = auth.uid()
        AND am.is_active = true
        AND am.permissions IS NOT NULL
        AND (
          (jsonb_typeof(to_jsonb(am.permissions)) = 'array'
             AND to_jsonb(am.permissions) ? p_permission)
          OR (jsonb_typeof(to_jsonb(am.permissions)) = 'object'
             AND COALESCE((to_jsonb(am.permissions) ->> p_permission)::boolean, false) = true)
        )
    );
$$;

GRANT EXECUTE ON FUNCTION public.current_agent_has_permission(text) TO authenticated, anon;

-- 2) Politiques SELECT additives, une par table/permission.
--    Le helper gère manage_* => on mappe la permission de VUE de chaque section.

-- Finance : transactions + wallets (view_finance)
DROP POLICY IF EXISTS agent_read_wallet_transactions ON public.wallet_transactions;
CREATE POLICY agent_read_wallet_transactions ON public.wallet_transactions
  FOR SELECT TO authenticated
  USING (public.current_agent_has_permission('view_finance'));

DROP POLICY IF EXISTS agent_read_wallets ON public.wallets;
CREATE POLICY agent_read_wallets ON public.wallets
  FOR SELECT TO authenticated
  USING (public.current_agent_has_permission('view_finance'));

-- Banque : alertes de sécurité financière (view_banking)
DROP POLICY IF EXISTS agent_read_financial_security_alerts ON public.financial_security_alerts;
CREATE POLICY agent_read_financial_security_alerts ON public.financial_security_alerts
  FOR SELECT TO authenticated
  USING (public.current_agent_has_permission('view_banking'));

-- Commandes : toutes les commandes plateforme (view_orders)
DROP POLICY IF EXISTS agent_read_orders ON public.orders;
CREATE POLICY agent_read_orders ON public.orders
  FOR SELECT TO authenticated
  USING (public.current_agent_has_permission('view_orders'));

-- Agents : voir tous les agents (view_agents)
DROP POLICY IF EXISTS agent_read_agents_management ON public.agents_management;
CREATE POLICY agent_read_agents_management ON public.agents_management
  FOR SELECT TO authenticated
  USING (public.current_agent_has_permission('view_agents'));

-- Sécurité : alertes + IP bloquées (view_security)
DROP POLICY IF EXISTS agent_read_security_alerts ON public.security_alerts;
CREATE POLICY agent_read_security_alerts ON public.security_alerts
  FOR SELECT TO authenticated
  USING (public.current_agent_has_permission('view_security'));

DROP POLICY IF EXISTS agent_read_blocked_ips ON public.blocked_ips;
CREATE POLICY agent_read_blocked_ips ON public.blocked_ips
  FOR SELECT TO authenticated
  USING (public.current_agent_has_permission('view_security'));

-- Surveillance plateforme : alertes système (view_platform_surveillance — onglet Surveillance)
DROP POLICY IF EXISTS agent_read_system_alerts ON public.system_alerts;
CREATE POLICY agent_read_system_alerts ON public.system_alerts
  FOR SELECT TO authenticated
  USING (
    public.current_agent_has_permission('view_platform_surveillance')
    OR public.current_agent_has_permission('view_finance')
  );
