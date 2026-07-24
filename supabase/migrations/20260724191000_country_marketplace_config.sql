-- ============================================================================
-- Configuration du marketplace PAR PAYS (annuaire fournisseurs paramétrable)
-- ============================================================================
-- P2 : la certification était obligatoire codée en dur → dans un pays neuf (aucun certifié),
-- l'annuaire renvoyait vide → l'app semblait cassée. On rend le comportement configurable par
-- pays, avec des DÉFAUTS = comportement actuel (certification requise, gros/detail_gros).
-- Après le seed, RIEN ne change tant que personne ne modifie la config. C'est voulu.
--
-- Idempotent : CREATE TABLE IF NOT EXISTS + seed ON CONFLICT DO NOTHING.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.country_marketplace_config (
  country_code          text PRIMARY KEY REFERENCES public.countries(country_code) ON DELETE CASCADE,
  suppliers_enabled     boolean NOT NULL DEFAULT true,
  require_certification  boolean NOT NULL DEFAULT true,
  allowed_sale_types    text[]  NOT NULL DEFAULT ARRAY['gros','detail_gros'],
  min_product_count     integer NOT NULL DEFAULT 0,
  max_results           integer NOT NULL DEFAULT 200,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid
);

ALTER TABLE public.country_marketplace_config ENABLE ROW LEVEL SECURITY;

-- Lecture publique (le marketplace est public : la config gouverne l'affichage anonyme)
DROP POLICY IF EXISTS cmc_read_all ON public.country_marketplace_config;
CREATE POLICY cmc_read_all ON public.country_marketplace_config
  FOR SELECT USING (true);

-- Écriture réservée PDG/admin — MÊME pattern que public.countries (policy countries_admin_write
-- = is_admin_or_pdg()). On ne réinvente aucun contrôle d'accès.
DROP POLICY IF EXISTS cmc_admin_write ON public.country_marketplace_config;
CREATE POLICY cmc_admin_write ON public.country_marketplace_config
  FOR ALL
  USING (is_admin_or_pdg())
  WITH CHECK (is_admin_or_pdg());

-- Seed : tous les pays actifs héritent du comportement actuel (défauts de la table)
INSERT INTO public.country_marketplace_config (country_code)
SELECT country_code FROM public.countries
ON CONFLICT (country_code) DO NOTHING;

COMMENT ON TABLE public.country_marketplace_config IS
  'Paramétrage par pays de l''annuaire fournisseurs du marketplace (activation, certification requise, types de vente autorisés, seuil catalogue, plafond résultats). Défauts = comportement historique. Écriture PDG/admin (is_admin_or_pdg).';
