-- ============================================================
-- MEDIA ENRICHI : plats restaurant + services + gate vidéo Elite
-- ============================================================

-- 1. Colonnes médias sur restaurant_menu_items
ALTER TABLE public.restaurant_menu_items
  ADD COLUMN IF NOT EXISTS images TEXT[] DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS video_url TEXT;

COMMENT ON COLUMN public.restaurant_menu_items.images   IS 'URLs images du plat (jusqu''à 5 selon plan)';
COMMENT ON COLUMN public.restaurant_menu_items.video_url IS 'Vidéo du plat max 45s — plan Elite uniquement';

-- 2. Colonnes médias sur professional_services (portfolio + vidéo promo)
ALTER TABLE public.professional_services
  ADD COLUMN IF NOT EXISTS portfolio_images TEXT[] DEFAULT '{}',
  ADD COLUMN IF NOT EXISTS promo_video_url TEXT;

COMMENT ON COLUMN public.professional_services.portfolio_images IS 'Portfolio photos du service (jusqu''à 10 selon plan)';
COMMENT ON COLUMN public.professional_services.promo_video_url   IS 'Vidéo de présentation max 45s — plan Elite uniquement';

-- 3. Durée vidéo mise à jour sur products (était 10s → 45s)
COMMENT ON COLUMN public.products.promotional_video IS 'Vidéo publicitaire max 45s — plan Elite uniquement';

-- 4. Colonne can_upload_video sur plans
ALTER TABLE public.plans
  ADD COLUMN IF NOT EXISTS can_upload_video BOOLEAN DEFAULT false;

UPDATE public.plans SET can_upload_video = true WHERE name = 'elite';

-- 5. Colonne can_upload_video sur service_plans
ALTER TABLE public.service_plans
  ADD COLUMN IF NOT EXISTS can_upload_video BOOLEAN DEFAULT false;

UPDATE public.service_plans SET can_upload_video = true WHERE name = 'elite';

-- 6. Index pour accélérer le filtre vidéo
CREATE INDEX IF NOT EXISTS idx_menu_items_video
  ON public.restaurant_menu_items(video_url)
  WHERE video_url IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_professional_services_promo_video
  ON public.professional_services(promo_video_url)
  WHERE promo_video_url IS NOT NULL;
