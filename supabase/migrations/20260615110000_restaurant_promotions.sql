-- ============================================================================
-- RESTAURANT — Promotions (PHASE 3, finalisation du service Restaurant)
-- ----------------------------------------------------------------------------
-- Le restaurateur crée des promotions (réduction %, livraison gratuite dès X, 2=1).
-- Le client voit les promos ACTIVES (RLS lecture publique sur is_active). Quota +
-- plage horaire gérés. Rejouable.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.restaurant_promotions (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  title                   text NOT NULL,
  promo_type              text NOT NULL CHECK (promo_type IN ('percentage','free_delivery','bogo')),
  value                   numeric(10,2) NOT NULL DEFAULT 0,   -- % (percentage) ou montant min (free_delivery)
  target_kind             text NOT NULL DEFAULT 'all' CHECK (target_kind IN ('all','category','item')),
  target_id               uuid,                                -- category_id / item_id selon target_kind
  start_time              time,                                -- plage horaire (ex. midi)
  end_time                time,
  quota                   integer,                             -- nb max de bénéficiaires (NULL = illimité)
  used_count              integer NOT NULL DEFAULT 0,
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz DEFAULT now(),
  updated_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_resto_promos_service ON public.restaurant_promotions (professional_service_id, is_active);

ALTER TABLE public.restaurant_promotions ENABLE ROW LEVEL SECURITY;

-- Le restaurateur gère SES promotions (réutilise le helper check_service_owner existant).
DROP POLICY IF EXISTS resto_promos_owner ON public.restaurant_promotions;
CREATE POLICY resto_promos_owner ON public.restaurant_promotions
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));

-- Lecture publique des promotions ACTIVES (affichage côté client).
DROP POLICY IF EXISTS resto_promos_public_read ON public.restaurant_promotions;
CREATE POLICY resto_promos_public_read ON public.restaurant_promotions
  FOR SELECT USING (is_active = true);

SELECT 'Table restaurant_promotions créée (RLS owner + lecture publique active).' AS status;
