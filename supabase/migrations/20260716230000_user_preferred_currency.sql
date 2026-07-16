-- ============================================================================
-- DEVISE D'AFFICHAGE CHOISIE PAR L'UTILISATEUR (chantier « devise = un CHOIX »)
-- profiles.preferred_currency : NULL = automatique (wallet/PDG > pays > géo).
-- AFFICHAGE UNIQUEMENT — ne change JAMAIS la devise des wallets ni des paiements.
-- RLS : couverte par la policy existante de self-update sur profiles (l'utilisateur
-- met à jour sa propre ligne) ; aucune nouvelle policy nécessaire.
-- ============================================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS preferred_currency text NULL;

-- Forme ISO 4217 stricte (3 lettres majuscules). La liste des devises proposées
-- est pilotée côté app (src/data/currencies.ts — source unique WORLD_CURRENCIES) ;
-- le CHECK garantit la forme, pas une liste figée en base qui divergerait.
ALTER TABLE public.profiles
  DROP CONSTRAINT IF EXISTS profiles_preferred_currency_check;
ALTER TABLE public.profiles
  ADD CONSTRAINT profiles_preferred_currency_check
  CHECK (preferred_currency IS NULL OR preferred_currency ~ '^[A-Z]{3}$');

COMMENT ON COLUMN public.profiles.preferred_currency IS
  'Devise d''affichage choisie par l''utilisateur (ISO 4217, ex. GNF/XOF/USD). NULL = automatique (devise wallet gérée PDG > pays verrouillé > géolocalisation). Affichage uniquement : les paiements restent dans la devise du wallet.';
