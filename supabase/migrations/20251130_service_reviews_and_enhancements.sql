-- Migration: Création table service_reviews et amélioration service_types
-- Date: 2025-11-30
-- Description: Système complet d'avis, horaires et géolocalisation pour services de proximité

-- 1. Table des avis sur les services
CREATE TABLE IF NOT EXISTS public.service_reviews (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES public.service_types(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  
  -- Contrainte: un utilisateur ne peut laisser qu'un seul avis par service
  UNIQUE(service_id, user_id)
);

-- 2. Table des horaires d'ouverture
CREATE TABLE IF NOT EXISTS public.service_opening_hours (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES public.service_types(id) ON DELETE CASCADE UNIQUE,
  monday_open TIME,
  monday_close TIME,
  tuesday_open TIME,
  tuesday_close TIME,
  wednesday_open TIME,
  wednesday_close TIME,
  thursday_open TIME,
  thursday_close TIME,
  friday_open TIME,
  friday_close TIME,
  saturday_open TIME,
  saturday_close TIME,
  sunday_open TIME,
  sunday_close TIME,
  is_24_7 BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 3. Table des favoris
CREATE TABLE IF NOT EXISTS public.service_favorites (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES public.service_types(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  
  UNIQUE(service_id, user_id)
);

-- 4. Table des réservations
CREATE TABLE IF NOT EXISTS public.service_bookings (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  service_id UUID NOT NULL REFERENCES public.service_types(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  booking_date DATE NOT NULL,
  booking_time TIME NOT NULL,
  status VARCHAR(50) DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'cancelled', 'completed')),
  notes TEXT,
  contact_phone VARCHAR(20),
  contact_email VARCHAR(255),
  created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- 5. Ajouter colonnes géolocalisation et contact à service_types
ALTER TABLE public.service_types 
  ADD COLUMN IF NOT EXISTS latitude DECIMAL(10, 8),
  ADD COLUMN IF NOT EXISTS longitude DECIMAL(11, 8),
  ADD COLUMN IF NOT EXISTS address TEXT,
  ADD COLUMN IF NOT EXISTS phone VARCHAR(20),
  ADD COLUMN IF NOT EXISTS email VARCHAR(255),
  ADD COLUMN IF NOT EXISTS website VARCHAR(500);

-- 6. Index pour les performances
CREATE INDEX IF NOT EXISTS idx_service_reviews_service ON public.service_reviews(service_id);
CREATE INDEX IF NOT EXISTS idx_service_reviews_user ON public.service_reviews(user_id);
CREATE INDEX IF NOT EXISTS idx_service_reviews_rating ON public.service_reviews(rating);
CREATE INDEX IF NOT EXISTS idx_service_bookings_service ON public.service_bookings(service_id);
CREATE INDEX IF NOT EXISTS idx_service_bookings_user ON public.service_bookings(user_id);
CREATE INDEX IF NOT EXISTS idx_service_bookings_date ON public.service_bookings(booking_date);
CREATE INDEX IF NOT EXISTS idx_service_favorites_user ON public.service_favorites(user_id);
CREATE INDEX IF NOT EXISTS idx_service_types_location ON public.service_types(latitude, longitude);

-- 7. Triggers pour updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = timezone('utc'::text, now());
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_service_reviews_updated_at
  BEFORE UPDATE ON public.service_reviews
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_service_opening_hours_updated_at
  BEFORE UPDATE ON public.service_opening_hours
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER trigger_service_bookings_updated_at
  BEFORE UPDATE ON public.service_bookings
  FOR EACH ROW
  EXECUTE FUNCTION update_updated_at_column();

-- 8. RLS (Row Level Security)
ALTER TABLE public.service_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_opening_hours ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_bookings ENABLE ROW LEVEL SECURITY;

-- Policies pour service_reviews
CREATE POLICY "Les avis sont lisibles par tous"
  ON public.service_reviews FOR SELECT
  USING (true);

CREATE POLICY "Les utilisateurs peuvent créer leurs avis"
  ON public.service_reviews FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs peuvent modifier leurs avis"
  ON public.service_reviews FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs peuvent supprimer leurs avis"
  ON public.service_reviews FOR DELETE
  USING (auth.uid() = user_id);

-- Policies pour service_opening_hours
CREATE POLICY "Les horaires sont lisibles par tous"
  ON public.service_opening_hours FOR SELECT
  USING (true);

-- Policies pour service_favorites
CREATE POLICY "Les favoris sont visibles par leur propriétaire"
  ON public.service_favorites FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs peuvent ajouter des favoris"
  ON public.service_favorites FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs peuvent supprimer leurs favoris"
  ON public.service_favorites FOR DELETE
  USING (auth.uid() = user_id);

-- Policies pour service_bookings
CREATE POLICY "Les réservations sont visibles par leur créateur"
  ON public.service_bookings FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs peuvent créer des réservations"
  ON public.service_bookings FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Les utilisateurs peuvent modifier leurs réservations"
  ON public.service_bookings FOR UPDATE
  USING (auth.uid() = user_id);

-- 9. Vue pour les statistiques des services
CREATE OR REPLACE VIEW public.service_stats AS
SELECT 
  st.id,
  st.name,
  COUNT(DISTINCT sr.id) as reviews_count,
  COALESCE(AVG(sr.rating), 0) as average_rating,
  COUNT(DISTINCT sf.user_id) as favorites_count,
  COUNT(DISTINCT sb.id) as bookings_count
FROM public.service_types st
LEFT JOIN public.service_reviews sr ON st.id = sr.service_id
LEFT JOIN public.service_favorites sf ON st.id = sf.service_id
LEFT JOIN public.service_bookings sb ON st.id = sb.service_id
GROUP BY st.id, st.name;

-- 10. Fonction pour calculer la distance entre deux points (Haversine)
CREATE OR REPLACE FUNCTION calculate_distance(
  lat1 DECIMAL,
  lon1 DECIMAL,
  lat2 DECIMAL,
  lon2 DECIMAL
)
RETURNS DECIMAL AS $$
DECLARE
  r DECIMAL := 6371; -- Rayon de la Terre en km
  dlat DECIMAL;
  dlon DECIMAL;
  a DECIMAL;
  c DECIMAL;
BEGIN
  dlat := radians(lat2 - lat1);
  dlon := radians(lon2 - lon1);
  
  a := sin(dlat/2) * sin(dlat/2) + 
       cos(radians(lat1)) * cos(radians(lat2)) * 
       sin(dlon/2) * sin(dlon/2);
  
  c := 2 * atan2(sqrt(a), sqrt(1-a));
  
  RETURN r * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 11. Données de test - Coordonnées Conakry et communes
UPDATE public.service_types
SET 
  latitude = 9.6412 + (random() * 0.1 - 0.05),
  longitude = -13.5784 + (random() * 0.1 - 0.05),
  address = 'Quartier ' || (ARRAY['Kaloum', 'Dixinn', 'Matam', 'Ratoma', 'Matoto'])[floor(random() * 5 + 1)] || ', Conakry',
  phone = '+224 6' || floor(random() * 90000000 + 10000000)::text
WHERE latitude IS NULL;

-- 12. Horaires par défaut pour tous les services
INSERT INTO public.service_opening_hours (service_id, monday_open, monday_close, tuesday_open, tuesday_close, wednesday_open, wednesday_close, thursday_open, thursday_close, friday_open, friday_close, saturday_open, saturday_close)
SELECT 
  id,
  '08:00'::TIME, '18:00'::TIME,
  '08:00'::TIME, '18:00'::TIME,
  '08:00'::TIME, '18:00'::TIME,
  '08:00'::TIME, '18:00'::TIME,
  '08:00'::TIME, '18:00'::TIME,
  '09:00'::TIME, '14:00'::TIME
FROM public.service_types
WHERE id NOT IN (SELECT service_id FROM public.service_opening_hours);

COMMENT ON TABLE public.service_reviews IS 'Avis et évaluations des services par les utilisateurs';
COMMENT ON TABLE public.service_opening_hours IS 'Horaires d''ouverture des services';
COMMENT ON TABLE public.service_favorites IS 'Services favoris des utilisateurs';
COMMENT ON TABLE public.service_bookings IS 'Réservations de services par les utilisateurs';
COMMENT ON VIEW public.service_stats IS 'Statistiques agrégées des services (avis, favoris, réservations)';
