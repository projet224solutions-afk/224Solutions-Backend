-- ============================================================================
-- payment_links : autoriser CHAUFFEUR (taxi) et LIVREUR à créer LEUR PROPRE lien de paiement
-- ----------------------------------------------------------------------------
-- La RLS d'INSERT exigeait has_active_feature(auth.uid(), 'payment_links') — une feature vendeur payante.
-- Un chauffeur/livreur (plan sans cette feature, ou abonnement expiré) était BLOQUÉ → « le lien ne se
-- crée pas ». Créer un lien qui crédite SON PROPRE wallet (owner_user_id = auth.uid()) est sans risque
-- (auto-crédit). On garde la feature pour les vendeurs et on AJOUTE les rôles 'taxi' et 'livreur'.
-- Rien d'autre ne change (USING inchangé, mêmes SELECT/DELETE policies).
-- ============================================================================

DROP POLICY IF EXISTS "Owners can manage their payment links" ON public.payment_links;

CREATE POLICY "Owners can manage their payment links" ON public.payment_links
  AS PERMISSIVE FOR ALL TO authenticated
  USING (owner_user_id = (SELECT auth.uid()))
  WITH CHECK (
    owner_user_id = (SELECT auth.uid())
    AND (
      public.has_active_feature((SELECT auth.uid()), 'payment_links')
      OR (SELECT role FROM public.profiles WHERE id = (SELECT auth.uid())) IN ('taxi', 'livreur')
    )
  );

SELECT 'payment_links : chauffeur (taxi) + livreur peuvent créer leur propre lien de paiement.' AS status;
