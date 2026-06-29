-- ============================================================================
-- COPILOTE DÉCOUVERTE STOCK — PARTIE 1 : localisation structurée des services.
-- professional_services a DÉJÀ city + neighborhood (vérifié live) ; seul `country`
-- manque → on l'ajoute + backfill best-effort depuis le profil du propriétaire.
-- ============================================================================

BEGIN;

ALTER TABLE public.professional_services
  ADD COLUMN IF NOT EXISTS country TEXT;

-- Backfill best-effort (n'écrase pas une valeur déjà présente).
UPDATE public.professional_services ps
SET country = COALESCE(ps.country, p.country),
    city    = COALESCE(ps.city, p.city)
FROM public.profiles p
WHERE p.id = ps.user_id
  AND (ps.country IS NULL OR ps.city IS NULL);

CREATE INDEX IF NOT EXISTS idx_ps_location ON public.professional_services (country, city);

COMMIT;
