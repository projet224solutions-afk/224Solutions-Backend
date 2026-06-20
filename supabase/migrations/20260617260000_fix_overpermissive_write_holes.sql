-- ============================================================================
-- 🔒 SÉCURITÉ — fermeture de trous « USING(true) pour {authenticated} » SÛRS à corriger.
--
-- Découverte pendant l'audit : des policies nommées « Admins… » étaient en fait permissives
-- `true` pour TOUT utilisateur connecté → n'importe quel compte pouvait lire/modifier/supprimer
-- toutes les lignes. On ferme UNIQUEMENT les cas où une policy légitime (propriétaire + admin)
-- existe déjà en repli, donc SANS casser l'usage normal.
--
-- ⛔ NON TRAITÉ ICI (casserait le frontend — à faire en projet dédié, scopé) :
--   • profiles  : 176 lectures directes au front (affichage des noms partout) → restreindre
--     casserait l'app ; nécessite une vue publique à colonnes limitées.
--   • vehicles  : 15 lectures front, 0 backend → géré entièrement côté client (bureaux) ;
--     restreindre sans policy bureau scopée casserait la gestion des véhicules.
--   • lecture drivers (9 front) : possible découverte de livreurs côté client → laissée ouverte.
-- ============================================================================

-- ── driver_subscriptions ────────────────────────────────────────────────────
-- Repli légitime conservé : « Users can manage driver subscriptions » (user_id = auth.uid()),
-- « admin_pdg_manage_all_subscriptions » (rôle admin/pdg), « Service role full access ».
-- On retire les 2 policies `true` (écriture ET lecture ouvertes à tout authentifié).
DROP POLICY IF EXISTS "Admins can view all subscriptions" ON public.driver_subscriptions;
DROP POLICY IF EXISTS "Users can view own subscriptions"   ON public.driver_subscriptions;

-- ── drivers ───────────────────────────────────────────────────────────────
-- Trou d'ÉCRITURE : « Admins can manage all drivers » = ALL `true` pour {authenticated}.
-- On le remplace par un vrai contrôle de rôle (admins/PDG only). Le propriétaire garde sa
-- policy « Drivers can manage their data » (user_id = auth.uid()). La LECTURE
-- (« Everyone can view verified drivers ») est laissée telle quelle (découverte livreurs).
DROP POLICY IF EXISTS "Admins can manage all drivers" ON public.drivers;
CREATE POLICY "Admins can manage all drivers" ON public.drivers
  FOR ALL TO authenticated
  USING (public.is_admin_or_pdg((select auth.uid())))
  WITH CHECK (public.is_admin_or_pdg((select auth.uid())));

SELECT 'Trous écriture fermés : driver_subscriptions (policies true retirées) + drivers (admin restreint au rôle). profiles/vehicles laissés (dépendances front) — à traiter en projet dédié.' AS status;
