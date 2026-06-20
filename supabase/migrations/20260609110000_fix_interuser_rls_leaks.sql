-- ============================================================================
-- SÉCURITÉ — Corriger les FUITES INTER-UTILISATEURS (RLS lecture)
-- ----------------------------------------------------------------------------
-- Audit (2026-06-09, JWT client forgé) : un utilisateur connecté A pouvait LIRE
-- les données d'un autre utilisateur B :
--   • notifications de B (46 lignes : contenu privé commandes/messages)
--   • escrow_transactions de B (13 lignes : montants, parties)
-- Cause : policy(ies) de LECTURE permissive(s) surchargent les bonnes (auth.uid()=user_id).
-- L'écriture restait bloquée ; on ne corrige que la LECTURE.
--
-- Méthode : retirer de façon déterministe TOUTES les policies SELECT/ALL (boucle
-- pg_policies) + drop explicite des policies nommées (rejouable), puis recréer les bonnes.
-- Le backend (service_role) CONTOURNE la RLS → écritures backend intactes.
--   • notifications : lecture/màj/suppression de SES notifications + insert client conservé (SOS).
--   • escrow : lecture par les PARTIES (buyer/seller/payer/receiver) + PDG/admin ; pas d'écriture client.
-- ⚠️ role comparé en ::text (l'enum user_role ne contient pas toutes les valeurs admin). Idempotent.
-- ============================================================================

-- ───────────── notifications : lecture = SES notifications uniquement ─────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT policyname FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'notifications' AND cmd IN ('SELECT', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.notifications', r.policyname);
  END LOOP;
END $$;

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "notif_select_own" ON public.notifications;
DROP POLICY IF EXISTS "notif_update_own" ON public.notifications;
DROP POLICY IF EXISTS "notif_delete_own" ON public.notifications;
DROP POLICY IF EXISTS "notif_insert_authenticated" ON public.notifications;

CREATE POLICY "notif_select_own" ON public.notifications
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE POLICY "notif_update_own" ON public.notifications
  FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

CREATE POLICY "notif_delete_own" ON public.notifications
  FOR DELETE TO authenticated USING (user_id = auth.uid());

-- Insert côté client conservé (ex. SOS taxi qui notifie des responders). Pas une fuite de lecture.
CREATE POLICY "notif_insert_authenticated" ON public.notifications
  FOR INSERT TO authenticated WITH CHECK (true);

-- ───────────── escrow_transactions : lecture = PARTIES + PDG/admin ─────────────
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT policyname FROM pg_policies
           WHERE schemaname = 'public' AND tablename = 'escrow_transactions' AND cmd IN ('SELECT', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.escrow_transactions', r.policyname);
  END LOOP;
END $$;

ALTER TABLE public.escrow_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "escrow_select_party" ON public.escrow_transactions;
DROP POLICY IF EXISTS "escrow_select_admin" ON public.escrow_transactions;

-- Seules les parties à la transaction la voient.
CREATE POLICY "escrow_select_party" ON public.escrow_transactions
  FOR SELECT TO authenticated
  USING (auth.uid() IN (buyer_id, seller_id, payer_id, receiver_id));

-- Le PDG / admin voit tout (interface de litiges escrow). role en ::text (enum-safe).
CREATE POLICY "escrow_select_admin" ON public.escrow_transactions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid() AND p.role::text IN ('admin', 'pdg', 'super_admin', 'ceo')
  ));

SELECT 'RLS inter-utilisateur corrigée : notifications (privées) + escrow (parties+PDG). Écriture backend intacte.' AS status;
