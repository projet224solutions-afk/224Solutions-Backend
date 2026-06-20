-- ============================================================================
-- 🔒 ISOLATION — PALIER 3b-2 : PII utilisateur (contacts, FCM, recherche, frappe…).
--
-- Suite de 20260617300000 (messagerie). Tables avec policies `true` malgré des noms
-- « their own ». Colonnes vérifiées dans les migrations de création :
--   user_contacts(user_id, contact_id) ; user_fcm_tokens(user_id) ;
--   user_search_history(user_id) ; typing_indicators(conversation_id, user_id).
--
-- Décisions :
--   • user_contacts / user_fcm_tokens / user_search_history : aucune policy scopée
--     n'existait (juste l'ouverte) → on REMPLACE par propriétaire (user_id = auth.uid()).
--   • notifications : déjà scopée en SELECT/UPDATE/DELETE (notif_*_own) ; on retire la
--     policy UPDATE ouverte redondante. L'INSERT reste ouvert : une notification est
--     légitimement créée POUR un AUTRE utilisateur (notifier le destinataire) — la
--     restreindre casserait les flux de notification ; l'isolation en LECTURE est déjà
--     assurée par notif_select_own. (À terme : créer les notifs côté backend.)
--   • typing_indicators : retire les 2 SELECT ouverts (dont un anon) → visible aux
--     participants de la conversation.
--   • user_presence : LAISSÉ tel quel — statut « en ligne » partagé par conception
--     (faible sensibilité), écriture déjà scopée (Users can update own presence).
--
-- Idempotent. Conserve les policies service_role.
-- ============================================================================

-- ── notifications : retirer l'UPDATE ouvert (les notif_*_own scopées restent) ──
DROP POLICY IF EXISTS "Users can update their own notifications" ON public.notifications;

-- ── typing_indicators : visible uniquement aux participants ──────────────────
DROP POLICY IF EXISTS "Users can view typing indicators" ON public.typing_indicators;
DROP POLICY IF EXISTS "Users can view typing in conversations" ON public.typing_indicators;
DROP POLICY IF EXISTS "typing_select_participants" ON public.typing_indicators;
CREATE POLICY "typing_select_participants" ON public.typing_indicators
  FOR SELECT TO authenticated
  USING (
    user_id = (select auth.uid())
    OR public.is_conversation_participant(conversation_id, (select auth.uid()))
  );
-- (la policy « Users can manage own typing » — ALL user_id=auth.uid() — est conservée)

-- ── user_contacts : propriétaire uniquement ─────────────────────────────────
DROP POLICY IF EXISTS "Users can view their own contacts"   ON public.user_contacts;
DROP POLICY IF EXISTS "Users can add their own contacts"    ON public.user_contacts;
DROP POLICY IF EXISTS "Users can delete their own contacts" ON public.user_contacts;
DROP POLICY IF EXISTS "user_contacts_owner_all" ON public.user_contacts;
CREATE POLICY "user_contacts_owner_all" ON public.user_contacts
  FOR ALL TO authenticated
  USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));
-- (service_role_all_contacts conservée)

-- ── user_fcm_tokens : propriétaire uniquement ───────────────────────────────
DROP POLICY IF EXISTS "Users can manage their own FCM tokens" ON public.user_fcm_tokens;
DROP POLICY IF EXISTS "user_fcm_tokens_owner_all" ON public.user_fcm_tokens;
CREATE POLICY "user_fcm_tokens_owner_all" ON public.user_fcm_tokens
  FOR ALL TO authenticated
  USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));

-- ── user_search_history : propriétaire uniquement (était ouvert à PUBLIC/anon) ─
DROP POLICY IF EXISTS "Users can manage search history" ON public.user_search_history;
DROP POLICY IF EXISTS "user_search_history_owner_all" ON public.user_search_history;
CREATE POLICY "user_search_history_owner_all" ON public.user_search_history
  FOR ALL TO authenticated
  USING (user_id = (select auth.uid()))
  WITH CHECK (user_id = (select auth.uid()));

SELECT 'Palier 3b-2 OK : user_contacts/user_fcm_tokens/user_search_history scopés propriétaire ; typing_indicators visible aux participants ; notifications UPDATE ouvert retiré (lecture déjà scopée) ; user_presence laissé (statut en ligne partagé).' AS status;
