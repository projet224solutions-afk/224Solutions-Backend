-- ============================================================================
-- AGRICULTURE (PHASE 3) — produits fermiers + TRAÇABILITÉ QR + commandes.
-- ----------------------------------------------------------------------------
-- Signature (JD Agriculture) : chaque produit a une page publique de traçabilité
-- (ferme, agriculteur, localisation, semis/récolte, méthode de culture) accessible
-- sans connexion via QR. RLS : l'agriculteur gère ses produits/commandes ; lecture
-- publique des produits (catalogue + traçabilité). Rejouable.
-- ============================================================================

-- ── Produits fermiers ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.farm_products (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  name                    text NOT NULL,
  category                text,
  description             text,
  unit                    text DEFAULT 'kg',
  price                   numeric(12,2) NOT NULL DEFAULT 0,
  stock_quantity          numeric(12,2) NOT NULL DEFAULT 0,
  low_stock_threshold     numeric(12,2) NOT NULL DEFAULT 10,
  photos                  text[] DEFAULT '{}',
  season                  text,
  origin                  text,
  organic                 boolean NOT NULL DEFAULT false,
  -- Traçabilité
  planting_date           date,
  harvest_date            date,
  culture_method          text DEFAULT 'conventionnel' CHECK (culture_method IN ('bio','traitement','conventionnel')),
  farm_name               text,
  farm_latitude           double precision,
  farm_longitude          double precision,
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz DEFAULT now(),
  updated_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_farm_products_service ON public.farm_products (professional_service_id, is_active);
CREATE INDEX IF NOT EXISTS idx_farm_products_category ON public.farm_products (category);

-- ── Commandes fermières ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.farm_orders (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  buyer_user_id           uuid REFERENCES auth.users(id),
  customer_name           text,
  customer_phone          text,
  items                   jsonb NOT NULL DEFAULT '[]',
  total                   numeric(12,2) NOT NULL DEFAULT 0,
  delivery_type           text DEFAULT 'livraison',
  status                  text NOT NULL DEFAULT 'nouveau' CHECK (status IN ('nouveau','confirme','prepare','expedie','livre','annule')),
  notes                   text,
  created_at              timestamptz DEFAULT now(),
  updated_at              timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_farm_orders_service ON public.farm_orders (professional_service_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_farm_orders_buyer ON public.farm_orders (buyer_user_id, created_at DESC);

-- ── RLS ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.farm_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.farm_orders ENABLE ROW LEVEL SECURITY;

-- Produits : l'agriculteur gère les siens ; lecture PUBLIQUE (catalogue + traçabilité QR).
DROP POLICY IF EXISTS farm_products_owner ON public.farm_products;
CREATE POLICY farm_products_owner ON public.farm_products
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS farm_products_public_read ON public.farm_products;
CREATE POLICY farm_products_public_read ON public.farm_products
  FOR SELECT USING (true);

-- Commandes : l'agriculteur gère celles de son service ; l'acheteur voit/crée les siennes.
DROP POLICY IF EXISTS farm_orders_owner ON public.farm_orders;
CREATE POLICY farm_orders_owner ON public.farm_orders
  FOR ALL USING (public.check_service_owner(professional_service_id))
  WITH CHECK (public.check_service_owner(professional_service_id));
DROP POLICY IF EXISTS farm_orders_buyer_select ON public.farm_orders;
CREATE POLICY farm_orders_buyer_select ON public.farm_orders
  FOR SELECT TO authenticated USING (buyer_user_id = auth.uid());
DROP POLICY IF EXISTS farm_orders_buyer_insert ON public.farm_orders;
CREATE POLICY farm_orders_buyer_insert ON public.farm_orders
  FOR INSERT TO authenticated WITH CHECK (buyer_user_id = auth.uid());

SELECT 'Système agriculture créé (farm_products + farm_orders + RLS owner/public/buyer).' AS status;
