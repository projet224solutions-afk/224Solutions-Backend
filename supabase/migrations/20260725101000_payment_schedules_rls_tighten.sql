-- ============================================================================
-- 🔴 PRIORITÉ — Fermer l'exposition RLS de public.payment_schedules
-- ============================================================================
-- La policy « Vendors can view their payment schedules » (SELECT, authenticated) avait
-- `USING (true)` → N'IMPORTE QUEL utilisateur connecté lisait TOUS les échéanciers de
-- paiement (montants, dates, clients de tous les vendeurs). Exposition de données
-- financières — mode de défaillance = trop LARGE (pas un refus).
--
-- L'accès LÉGITIME est déjà couvert par la policy scopée `users_own_payment_schedules`
-- (branche vendeur : EXISTS vendors v WHERE v.id = o.vendor_id AND v.user_id = auth.uid()).
-- On RETIRE donc simplement la policy trop large. On NE crée PAS d'accès nouveau.
--
-- ⚠️ VALIDATION THIERNO : confirmer qu'aucun écran vendeur ne dépendait de la lecture
-- GLOBALE (tous vendeurs). Si un tableau PDG lit tout, il passe par is_admin_or_pdg,
-- pas par cette policy.
-- ============================================================================

DROP POLICY IF EXISTS "Vendors can view their payment schedules" ON public.payment_schedules;

-- (Aucune CREATE : la lecture vendeur reste assurée par users_own_payment_schedules,
--  la lecture PDG par ses propres policies is_admin_or_pdg. Rien à ajouter.)
