-- ============================================================================
-- ADRESSE DE LIVRAISON FIABLE — Adresses enregistrées avec POINT GPS.
-- On ÉTEND la table existante `user_addresses` (carnet d'adresses déjà câblé au
-- hook useUserAddresses + Profil + ClientSettings) au lieu de créer une table
-- concurrente : un carnet unique, réutilisable par la livraison ET le taxi.
--   • lat/lng : le POINT de la destination (NULL = adresse sans point précis).
--   • complement : « étage 3, portail bleu » (complète l'adresse, ne la remplace pas).
-- RLS déjà en place (self-only : auth.uid() = user_id) — inchangée.
-- ============================================================================

ALTER TABLE public.user_addresses
  ADD COLUMN IF NOT EXISTS lat double precision,
  ADD COLUMN IF NOT EXISTS lng double precision,
  ADD COLUMN IF NOT EXISTS complement text;

COMMENT ON COLUMN public.user_addresses.lat IS 'Latitude du point de livraison (NULL si adresse sans point GPS).';
COMMENT ON COLUMN public.user_addresses.lng IS 'Longitude du point de livraison (NULL si adresse sans point GPS).';
COMMENT ON COLUMN public.user_addresses.complement IS 'Complément libre (étage, repère) — complète l''adresse.';
