-- ============================================================================
-- 🔒 ISOLATION — agent_created_users : fermeture du dernier INSERT ouvert.
--
-- Contexte : l'agent s'authentifie par token custom (access_token), PAS par session
-- Supabase — comme le bureau. La création/lecture/gestion des utilisateurs créés par
-- un agent passe DÉJÀ entièrement par le BACKEND Node.js (service_role, BYPASS RLS) :
--   • POST /api/agents/users            (création — vérifie access_token OU JWT + permission create_users)
--   • POST /api/agents/users/list       (liste)
--   • POST /api/agents/users/toggle-status / delete (gestion)
-- Côté frontend, useAgentActions/AgentCreatedUsersList/ManageUsersSection utilisent
-- backendFetch ; agentService.createUserByAgent est un stub mort (return null).
-- → AUCUN insert direct frontend.
--
-- FAILLE : la policy « allow_insert_agent_users » (INSERT, WITH CHECK true) permettait
-- à n'importe quel compte connecté d'attribuer un utilisateur à n'importe quel agent
-- (agent_id arbitraire) → falsification d'affiliation / commissions.
--
-- FIX : INSERT réservé à l'admin/PDG ; le backend agent passe par service_role
-- (BYPASS RLS) → inchangé. (Le SELECT est déjà scopé — non modifié.)
--
-- Idempotent.
-- ============================================================================

DROP POLICY IF EXISTS "allow_insert_agent_users" ON public.agent_created_users;
CREATE POLICY "agent_created_users_admin_insert" ON public.agent_created_users
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

SELECT 'agent_created_users : INSERT ouvert fermé → admin/PDG + backend service_role (création réelle via /api/agents/users). SELECT déjà scopé, inchangé.' AS status;
