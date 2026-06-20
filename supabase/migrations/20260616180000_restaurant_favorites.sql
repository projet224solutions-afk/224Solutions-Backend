-- ============================================================================
-- FAVORIS RESTAURANT (visible/géré uniquement CONNECTÉ). Table dédiée (la table
-- `favorites` existante est liée aux produits e-commerce). RLS : chacun ne voit/gère
-- que ses propres favoris.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.restaurant_favorites (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  professional_service_id uuid NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  created_at timestamptz DEFAULT now(),
  UNIQUE (user_id, professional_service_id)
);

CREATE INDEX IF NOT EXISTS idx_restaurant_favorites_user ON public.restaurant_favorites(user_id);

ALTER TABLE public.restaurant_favorites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "restaurant_favorites_select_own" ON public.restaurant_favorites;
CREATE POLICY "restaurant_favorites_select_own" ON public.restaurant_favorites
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "restaurant_favorites_insert_own" ON public.restaurant_favorites;
CREATE POLICY "restaurant_favorites_insert_own" ON public.restaurant_favorites
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "restaurant_favorites_delete_own" ON public.restaurant_favorites;
CREATE POLICY "restaurant_favorites_delete_own" ON public.restaurant_favorites
  FOR DELETE USING (auth.uid() = user_id);

SELECT 'Table restaurant_favorites créée (RLS : favoris privés par utilisateur).' AS status;
