-- ============================================================================
-- 🔒 ISOLATION — PALIER 3b-1 : MESSAGERIE (messages / conversations / participants).
--
-- Constat : ces 3 tables ont DÉJÀ d'excellentes policies scopées (migration
-- 20251029014224) via les helpers SECURITY DEFINER anti-récursion
-- is_conversation_participant / is_conversation_creator. MAIS des policies
-- permissives `true` ont été ajoutées par-dessus → elles ANNULENT l'isolation
-- (permissives = OR). On supprime ces ouvertes ; les scopées reprennent la main.
--
-- ⚠️ Particularité `messages` = SCHÉMA HYBRIDE :
--   • messages de conversation : conversation_id + participants (policies scopées OK) ;
--   • messages DIRECTS : sender_id/recipient_id SANS conversation_id (utilisés par
--     « contacter le vendeur » : useContactVendor, ProductDetail, VendorShop…).
--   Les policies scopées d'origine ne couvrent QUE le modèle conversation → on AJOUTE
--   des policies « message direct » pour ne pas casser le contact vendeur.
--
-- Flux d'écriture vérifiés (frontend) :
--   • conversations.insert → creator_id = user.id  → couvert par « Users can create… »
--   • conversation_participants.insert (créateur ajoute self + contact) → couvert par
--     « Creators can add participants » (is_conversation_creator = vrai pour le créateur)
--   • messages.insert conversation → sender = self + participant (policy existante)
--   • messages.insert direct → sender = self, conversation_id NULL (policy ajoutée)
--
-- Le drop ne retire QUE les policies entièrement ouvertes ; les scopées et les
-- policies service_role (auth.role()='service_role') sont préservées.
-- Idempotent.
-- ============================================================================

-- ── ÉTAPE 1 : retirer les policies entièrement ouvertes ──────────────────────
DO $$
DECLARE
  r record;
  targets text[] := ARRAY['messages','conversations','conversation_participants'];
BEGIN
  FOR r IN
    SELECT c.relname AS tbl, p.polname
    FROM pg_policy p
    JOIN pg_class c ON c.oid = p.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relname = ANY(targets)
      AND p.polpermissive
      AND (p.polqual IS NULL
           OR btrim(lower(pg_get_expr(p.polqual, p.polrelid))) = 'true')
      AND (p.polwithcheck IS NULL
           OR btrim(lower(pg_get_expr(p.polwithcheck, p.polrelid))) = 'true')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.polname, r.tbl);
    RAISE NOTICE 'Policy ouverte supprimée : % sur %', r.polname, r.tbl;
  END LOOP;
END $$;

-- ── ÉTAPE 2 : couvrir le modèle « message direct » (sans conversation_id) ────
-- Lecture : l'expéditeur et le destinataire voient leurs messages directs.
DROP POLICY IF EXISTS "messages_direct_select" ON public.messages;
CREATE POLICY "messages_direct_select" ON public.messages
  FOR SELECT TO authenticated
  USING (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()));

-- Envoi direct : on est l'expéditeur ET il n'y a pas de conversation (le cas
-- conversation reste géré par « Participants can send messages »).
DROP POLICY IF EXISTS "messages_direct_insert" ON public.messages;
CREATE POLICY "messages_direct_insert" ON public.messages
  FOR INSERT TO authenticated
  WITH CHECK (sender_id = (select auth.uid()) AND conversation_id IS NULL);

-- Mise à jour (statut lu / traduction audio) par l'une des deux parties.
DROP POLICY IF EXISTS "messages_direct_update" ON public.messages;
CREATE POLICY "messages_direct_update" ON public.messages
  FOR UPDATE TO authenticated
  USING (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()))
  WITH CHECK (sender_id = (select auth.uid()) OR recipient_id = (select auth.uid()));

SELECT 'Palier 3b-1 OK : messages/conversations/conversation_participants — ouvertes retirées (isolation conversation scopée restaurée) + couverture des messages directs (sender/recipient). Reste 3b-2 : notifications, user_contacts, user_fcm_tokens, user_presence, user_search_history, typing_indicators.' AS status;
