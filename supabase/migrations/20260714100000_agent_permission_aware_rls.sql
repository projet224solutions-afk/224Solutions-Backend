-- ============================================================================
-- RLS « CONSCIENTE DES PERMISSIONS AGENT » — supervision plateforme réelle
-- ----------------------------------------------------------------------------
-- CONTEXTE (audit project_agent_permissions_gap, test JWT agent réel) :
-- l'agent autorisé atterrit sur l'interface PDG FILTRÉE (/pdg, option B) mais les
-- onglets Finance/Banque/Sécurité/Agents s'affichent VIDES : le gating front est
-- correct, la RLS (la vraie frontière) ne connaît pas agent_permissions.
--   wallet_transactions : 0/219 lignes visibles ; financial_security_alerts : 0/162 ;
--   wallets : 1/28 (la sienne) ; orders : 1/365 ; agents_management : 1/5.
--
-- PRINCIPE : policies SELECT ADDITIVES (OR avec l'existant), lecture seule,
-- réservées aux agents ACTIFS dont le PDG a accordé la permission précise.
-- Le PDG reste le seul à accorder/retirer (set_agent_permissions). Aucune
-- écriture n'est ouverte par cette migration.
--
-- ⚠️ À VALIDER AVANT EXÉCUTION : ces policies donnent à un agent autorisé la
-- lecture PLateforme ENTIÈRE des tables listées (c'est l'objet même de la
-- supervision déléguée). Ne l'appliquer que si ce niveau de délégation est voulu.
-- ============================================================================

-- ── Helper : l'utilisateur courant est-il un agent ACTIF ayant la permission ? ──
-- STABLE + SECURITY DEFINER (lit agents_management/agent_permissions sous RLS
-- contournée — nécessaire car l'agent ne voit que sa propre ligne).
-- Alias view_* ⇐ manage_* : accorder « manage_x » implique « view_x » (même
-- convention que hasPermissionWithAliases côté front).
CREATE OR REPLACE FUNCTION public.agent_has_permission(p_permission_key text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.agents_management am
    WHERE am.user_id = auth.uid()
      AND am.is_active = true
      AND (
        EXISTS (
          SELECT 1 FROM public.agent_permissions ap
          WHERE ap.agent_id = am.id
            AND ap.permission_value = true
            AND ap.permission_key IN (
              p_permission_key,
              replace(p_permission_key, 'view_', 'manage_')
            )
        )
        -- Colonne legacy agents_management.permissions (JSONB array) toujours fusionnée
        -- en OR côté front (useAgentPermissionsUnified) → même règle ici. L'opérateur jsonb `?`
        -- teste l'appartenance d'une chaîne aux éléments d'un tableau jsonb (null-safe via le guard).
        OR (am.permissions IS NOT NULL AND jsonb_typeof(am.permissions) = 'array'
            AND am.permissions ? p_permission_key)
        OR (am.permissions IS NOT NULL AND jsonb_typeof(am.permissions) = 'array'
            AND am.permissions ? replace(p_permission_key, 'view_', 'manage_'))
      )
  );
$$;

REVOKE ALL ON FUNCTION public.agent_has_permission(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.agent_has_permission(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.agent_has_permission(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.agent_has_permission(text) TO service_role;

-- ── Policies SELECT additives (une permission précise par table) ────────────────
-- NB : les policies RLS d'une même table se combinent en OR — l'existant
-- (propriétaire voit les siennes, admin/PDG voit tout) est INCHANGÉ.

-- Onglet Banque : tous les wallets (soldes) — permission view_banking.
DROP POLICY IF EXISTS "agents_with_view_banking_read_wallets" ON public.wallets;
CREATE POLICY "agents_with_view_banking_read_wallets"
  ON public.wallets FOR SELECT
  USING (public.agent_has_permission('view_banking'));

-- Onglet Transactions wallet : le journal — permission view_wallet_transactions
-- (ou manage_wallet_transactions via l'alias du helper).
DROP POLICY IF EXISTS "agents_with_view_wallet_tx_read_wallet_transactions" ON public.wallet_transactions;
CREATE POLICY "agents_with_view_wallet_tx_read_wallet_transactions"
  ON public.wallet_transactions FOR SELECT
  USING (public.agent_has_permission('view_wallet_transactions'));

-- Onglet Commandes : toutes les commandes — permission view_orders.
DROP POLICY IF EXISTS "agents_with_view_orders_read_orders" ON public.orders;
CREATE POLICY "agents_with_view_orders_read_orders"
  ON public.orders FOR SELECT
  USING (public.agent_has_permission('view_orders'));

-- Onglet Sécurité : alertes financières — permission view_security.
DROP POLICY IF EXISTS "agents_with_view_security_read_fin_alerts" ON public.financial_security_alerts;
CREATE POLICY "agents_with_view_security_read_fin_alerts"
  ON public.financial_security_alerts FOR SELECT
  USING (public.agent_has_permission('view_security'));

-- Onglet Agents : la liste des agents — permission view_agents.
DROP POLICY IF EXISTS "agents_with_view_agents_read_agents_management" ON public.agents_management;
CREATE POLICY "agents_with_view_agents_read_agents_management"
  ON public.agents_management FOR SELECT
  USING (public.agent_has_permission('view_agents'));

-- ── Vérification rapide post-application (à exécuter à la main) ─────────────────
-- SELECT public.agent_has_permission('view_banking');            -- en tant qu'agent doté → true
-- SELECT count(*) FROM public.wallet_transactions;               -- agent doté → > 0
-- (et re-tester avec un agent SANS la permission → comptes inchangés, lignes propres seulement)
