-- ============================================================================
-- SYSTÈME DE SERVICES PROFESSIONNELS 224SOLUTIONS
-- Migration complète pour gestion multi-services
-- ============================================================================

-- Table principale des types de services disponibles
CREATE TABLE IF NOT EXISTS public.service_types (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code VARCHAR(50) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL,
  description TEXT,
  icon VARCHAR(50),
  category VARCHAR(50),
  is_active BOOLEAN DEFAULT true,
  features JSONB DEFAULT '[]'::jsonb,
  commission_rate DECIMAL(5,2) DEFAULT 5.00,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des services professionnels créés par les utilisateurs
CREATE TABLE IF NOT EXISTS public.professional_services (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  service_type_id UUID NOT NULL REFERENCES public.service_types(id),
  business_name VARCHAR(200) NOT NULL,
  description TEXT,
  logo_url TEXT,
  cover_image_url TEXT,
  address TEXT,
  phone VARCHAR(20),
  email VARCHAR(100),
  website VARCHAR(200),
  opening_hours JSONB DEFAULT '{}'::jsonb,
  business_documents JSONB DEFAULT '[]'::jsonb,
  status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'suspended', 'rejected')),
  verification_status VARCHAR(20) DEFAULT 'unverified' CHECK (verification_status IN ('unverified', 'pending', 'verified', 'rejected')),
  rating DECIMAL(3,2) DEFAULT 0.00,
  total_reviews INTEGER DEFAULT 0,
  total_orders INTEGER DEFAULT 0,
  total_revenue DECIMAL(15,2) DEFAULT 0.00,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des produits/services offerts (pour e-commerce, restaurant, etc.)
CREATE TABLE IF NOT EXISTS public.service_products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  name VARCHAR(200) NOT NULL,
  description TEXT,
  category VARCHAR(100),
  price DECIMAL(15,2) NOT NULL,
  compare_at_price DECIMAL(15,2),
  images JSONB DEFAULT '[]'::jsonb,
  stock_quantity INTEGER DEFAULT 0,
  is_available BOOLEAN DEFAULT true,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des réservations/commandes
CREATE TABLE IF NOT EXISTS public.service_bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id),
  client_id UUID NOT NULL REFERENCES auth.users(id),
  booking_type VARCHAR(50) NOT NULL,
  scheduled_date TIMESTAMP WITH TIME ZONE,
  status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'in_progress', 'completed', 'cancelled')),
  total_amount DECIMAL(15,2) NOT NULL,
  commission_amount DECIMAL(15,2) DEFAULT 0.00,
  payment_status VARCHAR(20) DEFAULT 'pending' CHECK (payment_status IN ('pending', 'paid', 'refunded')),
  notes TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Table des avis clients
CREATE TABLE IF NOT EXISTS public.service_reviews (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  client_id UUID NOT NULL REFERENCES auth.users(id),
  booking_id UUID REFERENCES public.service_bookings(id),
  rating INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
  comment TEXT,
  images JSONB DEFAULT '[]'::jsonb,
  is_verified BOOLEAN DEFAULT false,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
  UNIQUE(booking_id, client_id)
);

-- Indexes pour optimisation
CREATE INDEX IF NOT EXISTS idx_service_types_code ON public.service_types(code);
CREATE INDEX IF NOT EXISTS idx_service_types_active ON public.service_types(is_active);
CREATE INDEX IF NOT EXISTS idx_professional_services_user ON public.professional_services(user_id);
CREATE INDEX IF NOT EXISTS idx_professional_services_type ON public.professional_services(service_type_id);
CREATE INDEX IF NOT EXISTS idx_professional_services_status ON public.professional_services(status);
CREATE INDEX IF NOT EXISTS idx_service_products_service ON public.service_products(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_service_products_available ON public.service_products(is_available);
CREATE INDEX IF NOT EXISTS idx_service_bookings_service ON public.service_bookings(professional_service_id);
CREATE INDEX IF NOT EXISTS idx_service_bookings_client ON public.service_bookings(client_id);
CREATE INDEX IF NOT EXISTS idx_service_bookings_status ON public.service_bookings(status);
CREATE INDEX IF NOT EXISTS idx_service_reviews_service ON public.service_reviews(professional_service_id);

-- Trigger pour updated_at
CREATE OR REPLACE FUNCTION update_service_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_service_types_updated_at
  BEFORE UPDATE ON public.service_types
  FOR EACH ROW
  EXECUTE FUNCTION update_service_updated_at();

CREATE TRIGGER trigger_professional_services_updated_at
  BEFORE UPDATE ON public.professional_services
  FOR EACH ROW
  EXECUTE FUNCTION update_service_updated_at();

CREATE TRIGGER trigger_service_products_updated_at
  BEFORE UPDATE ON public.service_products
  FOR EACH ROW
  EXECUTE FUNCTION update_service_updated_at();

CREATE TRIGGER trigger_service_bookings_updated_at
  BEFORE UPDATE ON public.service_bookings
  FOR EACH ROW
  EXECUTE FUNCTION update_service_updated_at();

-- Enable RLS
ALTER TABLE public.service_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.professional_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_reviews ENABLE ROW LEVEL SECURITY;

-- RLS Policies pour service_types (lecture publique)
CREATE POLICY "Service types are viewable by everyone"
  ON public.service_types FOR SELECT
  USING (is_active = true);

-- RLS Policies pour professional_services
CREATE POLICY "Users can view active professional services"
  ON public.professional_services FOR SELECT
  USING (status = 'active' OR user_id = auth.uid());

CREATE POLICY "Users can create their own professional services"
  ON public.professional_services FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own professional services"
  ON public.professional_services FOR UPDATE
  USING (auth.uid() = user_id);

-- RLS Policies pour service_products
CREATE POLICY "Users can view available products"
  ON public.service_products FOR SELECT
  USING (
    is_available = true 
    OR professional_service_id IN (
      SELECT id FROM public.professional_services WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Service owners can manage their products"
  ON public.service_products FOR ALL
  USING (
    professional_service_id IN (
      SELECT id FROM public.professional_services WHERE user_id = auth.uid()
    )
  );

-- RLS Policies pour service_bookings
CREATE POLICY "Users can view their bookings"
  ON public.service_bookings FOR SELECT
  USING (
    client_id = auth.uid() 
    OR professional_service_id IN (
      SELECT id FROM public.professional_services WHERE user_id = auth.uid()
    )
  );

CREATE POLICY "Clients can create bookings"
  ON public.service_bookings FOR INSERT
  WITH CHECK (auth.uid() = client_id);

CREATE POLICY "Service owners can update bookings"
  ON public.service_bookings FOR UPDATE
  USING (
    professional_service_id IN (
      SELECT id FROM public.professional_services WHERE user_id = auth.uid()
    )
  );

-- RLS Policies pour service_reviews
CREATE POLICY "Reviews are viewable by everyone"
  ON public.service_reviews FOR SELECT
  USING (true);

CREATE POLICY "Clients can create reviews"
  ON public.service_reviews FOR INSERT
  WITH CHECK (auth.uid() = client_id);

-- Insertion des 15 types de services
INSERT INTO public.service_types (code, name, description, icon, category, features, commission_rate) VALUES
('menage', 'Ménage & Entretien', 'Services de nettoyage et entretien à domicile', '🧹', 'services', '["Réservation instantanée", "Gestion d''équipe", "Planning intelligent", "Système d''évaluation"]'::jsonb, 10.00),
('livraison', 'Livraison / Coursier', 'Service de livraison et coursier rapide', '📦', 'transport', '["Suivi GPS temps réel", "Estimation automatique", "Chat intégré", "Historique complet"]'::jsonb, 15.00),
('ecommerce', 'Boutique Digitale', 'E-commerce et dropshipping', '🛒', 'commerce', '["Gestion catalogue", "Dropshipping", "Statistiques vente", "Coupons promo", "Suivi colis"]'::jsonb, 8.00),
('reparation', 'Service de Réparation', 'Plomberie, électricité, mécanique', '🧰', 'services', '["Devis en ligne", "Paiement sécurisé", "Notes fiabilité", "Géolocalisation"]'::jsonb, 12.00),
('location', 'Location Immobilière', 'Location de logements et propriétés', '🏡', 'immobilier', '["Calendrier disponibilité", "Caution virtuelle", "Facturation auto", "Multi-logement"]'::jsonb, 5.00),
('education', 'Éducation / Formation', 'Cours en ligne et formation', '🧑‍🏫', 'education', '["Cours vidéo", "Quiz interactifs", "Certificats", "Tableau de bord élève"]'::jsonb, 20.00),
('restaurant', 'Restauration', 'Restaurant et livraison de repas', '🍽️', 'food', '["Menu dynamique", "Commande en ligne", "Gestion stock", "Livraison intégrée", "Réservations"]'::jsonb, 10.00),
('beaute', 'Beauté & Bien-être', 'Salons de beauté et soins', '💇', 'services', '["Réservation en ligne", "Gestion employés", "Promotions", "Portfolio"]'::jsonb, 12.00),
('voyage', 'Voyage & Billetterie', 'Réservation voyages et transports', '🧳', 'transport', '["Comparateur prix", "QR Code", "Multi-devises", "Remboursement auto"]'::jsonb, 7.00),
('freelance', 'Services Administratifs', 'Freelance et services professionnels', '🧾', 'services', '["Profil pro", "Devis", "Paiement sécurisé", "Système avis"]'::jsonb, 15.00),
('sante', 'Santé & Bien-être', 'Consultations médicales', '🧑‍⚕️', 'health', '["Rendez-vous en ligne", "Téléconsultation", "Dossier médical", "Ordonnances PDF"]'::jsonb, 5.00),
('agriculture', 'Service Agricole', 'Vente produits et location matériel', '🚜', 'agriculture', '["Vente produits", "Location matériel", "Traçabilité", "Livraison auto"]'::jsonb, 8.00),
('construction', 'Construction & BTP', 'Gestion projets et chantiers', '👷', 'construction', '["Gestion projets", "Devis", "Suivi photos", "Paiement par étape"]'::jsonb, 10.00),
('media', 'Média & Création', 'Création de contenu multimédia', '🎥', 'creative', '["Upload fichiers", "Révisions", "Portfolio", "Avis publics"]'::jsonb, 18.00),
('informatique', 'Technique & Informatique', 'Assistance et support technique', '🧑‍💻', 'tech', '["Assistance distance", "Chat technique", "Ticket support", "Certification"]'::jsonb, 15.00)
ON CONFLICT (code) DO NOTHING;