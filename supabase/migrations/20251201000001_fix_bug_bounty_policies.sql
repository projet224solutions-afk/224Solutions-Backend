-- ============================================
-- FIX BUG BOUNTY POLICIES - 224SOLUTIONS
-- ============================================
-- Date: 2025-12-01
-- Objectif: Corriger les policies RLS qui utilisent has_role() inexistante
--          Remplacer par is_admin() qui existe déjà

-- Supprimer les anciennes policies problématiques
DROP POLICY IF EXISTS "Admins can view all bug reports" ON public.bug_reports;
DROP POLICY IF EXISTS "Admins can update bug reports" ON public.bug_reports;
DROP POLICY IF EXISTS "Admins can manage rewards" ON public.bug_bounty_rewards;
DROP POLICY IF EXISTS "Admins can manage hall of fame" ON public.bug_bounty_hall_of_fame;

-- ============================================
-- POLICIES POUR BUG_REPORTS
-- ============================================

-- Tout le monde peut soumettre des rapports (inchangé)
-- Cette policy existe déjà: "Anyone can submit bug reports"

-- ✅ Admins (PDG) peuvent voir tous les rapports
CREATE POLICY "Admins can view all bug reports"
ON public.bug_reports
FOR SELECT
TO authenticated
USING (public.is_admin(auth.uid()));

-- ✅ Admins (PDG) peuvent mettre à jour les rapports
CREATE POLICY "Admins can update bug reports"
ON public.bug_reports
FOR UPDATE
TO authenticated
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

-- ============================================
-- POLICIES POUR BUG_BOUNTY_REWARDS
-- ============================================

-- ✅ Admins (PDG) peuvent gérer les récompenses
CREATE POLICY "Admins can manage rewards"
ON public.bug_bounty_rewards
FOR ALL
TO authenticated
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

-- ============================================
-- POLICIES POUR BUG_BOUNTY_HALL_OF_FAME
-- ============================================

-- Lecture publique existe déjà: "Anyone can view hall of fame"

-- ✅ Admins (PDG) peuvent gérer le hall of fame
CREATE POLICY "Admins can manage hall of fame"
ON public.bug_bounty_hall_of_fame
FOR ALL
TO authenticated
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

-- ============================================
-- COMMENTAIRES
-- ============================================

COMMENT ON POLICY "Admins can view all bug reports" ON public.bug_reports IS 
'Permet aux administrateurs (PDG) de voir tous les rapports de bug bounty';

COMMENT ON POLICY "Admins can update bug reports" ON public.bug_reports IS 
'Permet aux administrateurs (PDG) de mettre à jour les statuts, récompenses et notes';

COMMENT ON POLICY "Admins can manage rewards" ON public.bug_bounty_rewards IS 
'Permet aux administrateurs (PDG) de gérer les paiements de récompenses';

COMMENT ON POLICY "Admins can manage hall of fame" ON public.bug_bounty_hall_of_fame IS 
'Permet aux administrateurs (PDG) de gérer le hall of fame des chercheurs';
