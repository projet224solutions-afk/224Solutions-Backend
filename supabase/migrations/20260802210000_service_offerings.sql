-- ═══════════════════════════════════════════════════════════════════════════════
-- PRESTATIONS IT — Bloc 1 : table service_offerings (catalogue de prestations d'un prestataire)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Livré en FICHIER — appliqué en prod via l'API Management.
--
-- Une « prestation » = une offre catalogue publiée par un prestataire (reliée à SON professional_service).
-- Le client la voit (si active) et la « Commande » → cela crée un service_quotes pré-rempli (Bloc 3), qui
-- réutilise le circuit d'argent EXISTANT (pay_service_quote / release). AUCUN nouveau chemin d'argent ici.

CREATE TABLE IF NOT EXISTS public.service_offerings (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  title                   text NOT NULL CHECK (char_length(btrim(title)) BETWEEN 3 AND 120),
  description             text CHECK (description IS NULL OR char_length(description) <= 2000),
  category                text CHECK (category IS NULL OR char_length(category) <= 60),
  -- Prix « à partir de » (le devis final peut détailler des lignes) — borné pour éviter les valeurs absurdes.
  base_price              numeric(12,2) NOT NULL DEFAULT 0 CHECK (base_price >= 0 AND base_price <= 100000000),
  currency                text NOT NULL DEFAULT 'GNF' CHECK (currency = upper(currency) AND char_length(currency) = 3),
  unit                    text CHECK (unit IS NULL OR char_length(unit) <= 30),   -- ex. 'forfait', 'jour', 'heure'
  delivery_days           int  CHECK (delivery_days IS NULL OR (delivery_days >= 0 AND delivery_days <= 3650)),
  escrow                  boolean NOT NULL DEFAULT true,   -- prestations : séquestre par défaut (validation client)
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_service_offerings_service ON public.service_offerings (professional_service_id, is_active);
CREATE INDEX IF NOT EXISTS idx_service_offerings_active_cat ON public.service_offerings (is_active, category);
-- Recherche par titre : ILIKE (volume faible) ; un index trigram (pg_trgm) pourra être ajouté plus tard si besoin.
CREATE INDEX IF NOT EXISTS idx_service_offerings_title_lower ON public.service_offerings (lower(title));

-- updated_at auto
CREATE OR REPLACE FUNCTION public.service_offerings_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END; $$;
DROP TRIGGER IF EXISTS trg_service_offerings_touch ON public.service_offerings;
CREATE TRIGGER trg_service_offerings_touch BEFORE UPDATE ON public.service_offerings
  FOR EACH ROW EXECUTE FUNCTION public.service_offerings_touch_updated_at();

-- ─── RLS ───────────────────────────────────────────────────────────────────────
ALTER TABLE public.service_offerings ENABLE ROW LEVEL SECURITY;

-- Owner (prestataire) : contrôle total sur SES prestations (via check_service_owner, déjà existant).
DROP POLICY IF EXISTS offerings_owner ON public.service_offerings;
CREATE POLICY offerings_owner ON public.service_offerings
  FOR ALL
  USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));

-- Lecture PUBLIQUE des prestations ACTIVES (vitrine marketplace, sans compte).
DROP POLICY IF EXISTS offerings_public_read_active ON public.service_offerings;
CREATE POLICY offerings_public_read_active ON public.service_offerings
  FOR SELECT
  USING (is_active = true);

REVOKE ALL ON public.service_offerings FROM anon;
GRANT SELECT ON public.service_offerings TO anon;              -- lecture des actives (RLS filtre)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.service_offerings TO authenticated;  -- owner via RLS
GRANT ALL ON public.service_offerings TO service_role;

-- ═══════════════════════════════════════════════════════════════════════════════
-- Vérifs post-application :
--   • table + 3 index + trigger updated_at présents ;
--   • RLS active : 2 policies (offerings_owner, offerings_public_read_active) ;
--   • anon peut SELECT une offering active ; ne peut PAS en insérer.
-- ═══════════════════════════════════════════════════════════════════════════════
