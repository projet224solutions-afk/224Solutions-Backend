-- ============================================================================
-- ⚡ INDEX DES CHEMINS CHAUDS — préparation à la montée en charge (§4)
-- ----------------------------------------------------------------------------
-- Audit des tables les plus sollicitées : quatre filtres très fréquents n'avaient
-- AUCUN index. Sur de petites tables cela ne se voit pas ; à quelques milliers
-- d'utilisateurs simultanés, chaque requête devient un balayage complet.
--
--   professional_services.user_id        → « ma fiche » sur CHAQUE écran prestataire,
--                                          et le pont transitaire à chaque chargement
--   professional_services.service_type_id → la liste proximité PAR CATÉGORIE
--   btp_projects (city, status)          → listes de chantiers filtrées
--   transit_partner_mandates.status      → lu par la RLS À CHAQUE prélèvement
--
-- Le dernier est le plus sensible : la RLS des mandats évalue le statut à chaque
-- requête (c'est ce qui rend la révocation immédiate). Sans index, ce contrôle
-- de sécurité devient lui-même le goulot.
--
-- `service_types.is_active` est volontairement OMIS : 28 lignes, l'index coûterait
-- plus cher à maintenir qu'un balayage. Indexer par réflexe est une erreur.
--
-- Aucun changement de logique ni de flux financier. Idempotent.
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_prof_services_user      ON public.professional_services (user_id);
CREATE INDEX IF NOT EXISTS idx_prof_services_type      ON public.professional_services (service_type_id);
-- Composite pour la liste proximité : filtre type + statut en une seule passe.
CREATE INDEX IF NOT EXISTS idx_prof_services_type_actif ON public.professional_services (service_type_id, status);

CREATE INDEX IF NOT EXISTS idx_btp_projects_city       ON public.btp_projects (city);
CREATE INDEX IF NOT EXISTS idx_btp_projects_status     ON public.btp_projects (status);

-- Partiel : seuls les mandats ACTIFS sont lus par la RLS ; indexer les révoqués
-- gonflerait l'index sans jamais servir.
CREATE INDEX IF NOT EXISTS idx_mandates_active ON public.transit_partner_mandates (granted_to, granted_by)
  WHERE status = 'active';

ANALYZE public.professional_services;
ANALYZE public.transit_partner_mandates;

SELECT 'Index des chemins chauds posés (fiches, catégories, chantiers, mandats).' AS status;
