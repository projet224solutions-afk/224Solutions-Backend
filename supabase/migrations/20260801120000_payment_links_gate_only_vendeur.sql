-- ============================================================================
-- payment_links : ne garder la feature payante QUE pour les VENDEURS ; libérer les autres rôles
-- ----------------------------------------------------------------------------
-- Suite : la version précédente n'autorisait que 'taxi'/'livreur'. Or le PDG (qui teste toutes les
-- interfaces) et d'autres rôles (agent, prestataire…) restaient bloqués. Créer un lien qui crédite SON
-- PROPRE wallet (owner_user_id = auth.uid()) est SANS RISQUE quel que soit le rôle. On inverse donc la
-- logique : seul le rôle 'vendeur' reste soumis à la feature payante 'payment_links' (monétisation
-- conservée) ; TOUS les autres rôles (taxi, livreur, pdg, agent, prestataire, client, actionnaire…)
-- peuvent créer leur propre lien de paiement. Aucune écriture vers le wallet d'autrui n'est possible
-- (owner_user_id = auth.uid()).
-- ============================================================================

DROP POLICY IF EXISTS "Owners can manage their payment links" ON public.payment_links;

CREATE POLICY "Owners can manage their payment links" ON public.payment_links
  AS PERMISSIVE FOR ALL TO authenticated
  USING (owner_user_id = (SELECT auth.uid()))
  WITH CHECK (
    owner_user_id = (SELECT auth.uid())
    AND (
      (SELECT role FROM public.profiles WHERE id = (SELECT auth.uid())) <> 'vendeur'
      OR public.has_active_feature((SELECT auth.uid()), 'payment_links')
    )
  );

SELECT 'payment_links : seul le vendeur reste gaté par la feature ; taxi/livreur/pdg/autres peuvent créer leur lien.' AS status;
