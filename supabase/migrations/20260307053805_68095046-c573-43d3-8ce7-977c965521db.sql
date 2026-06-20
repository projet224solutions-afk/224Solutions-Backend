
-- Table des biens immobiliers
CREATE TABLE public.properties (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  owner_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  description TEXT,
  offer_type TEXT NOT NULL CHECK (offer_type IN ('vente', 'location')),
  property_type TEXT NOT NULL CHECK (property_type IN ('appartement', 'maison', 'terrain', 'bureau', 'boutique', 'commerce', 'villa')),
  price NUMERIC NOT NULL DEFAULT 0,
  currency TEXT DEFAULT 'GNF',
  surface NUMERIC DEFAULT 0,
  rooms INTEGER DEFAULT 0,
  bathrooms INTEGER DEFAULT 0,
  address TEXT,
  city TEXT,
  neighborhood TEXT,
  latitude NUMERIC,
  longitude NUMERIC,
  amenities TEXT[] DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'disponible' CHECK (status IN ('disponible', 'sous_option', 'vendu', 'loue', 'brouillon')),
  is_featured BOOLEAN DEFAULT false,
  views_count INTEGER DEFAULT 0,
  favorites_count INTEGER DEFAULT 0,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Images des biens
CREATE TABLE public.property_images (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id UUID NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  image_url TEXT NOT NULL,
  display_order INTEGER DEFAULT 0,
  is_cover BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- Favoris des biens
CREATE TABLE public.property_favorites (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id UUID NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(property_id, user_id)
);

-- Visites planifiées
CREATE TABLE public.property_visits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  property_id UUID NOT NULL REFERENCES public.properties(id) ON DELETE CASCADE,
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  client_name TEXT NOT NULL,
  client_phone TEXT,
  client_email TEXT,
  visit_date DATE NOT NULL,
  visit_time TEXT,
  status TEXT DEFAULT 'planifiee' CHECK (status IN ('planifiee', 'effectuee', 'annulee')),
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Contacts immobilier
CREATE TABLE public.property_contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  professional_service_id UUID NOT NULL REFERENCES public.professional_services(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  phone TEXT,
  email TEXT,
  contact_type TEXT DEFAULT 'acheteur' CHECK (contact_type IN ('acheteur', 'vendeur', 'locataire', 'bailleur')),
  interested_in TEXT[] DEFAULT '{}',
  budget NUMERIC,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- RLS
ALTER TABLE public.properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_visits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.property_contacts ENABLE ROW LEVEL SECURITY;

-- Properties: owner can CRUD, others can read active
CREATE POLICY "Owner can manage properties" ON public.properties
  FOR ALL TO authenticated USING (owner_id = auth.uid());

CREATE POLICY "Public can view available properties" ON public.properties
  FOR SELECT TO authenticated USING (status IN ('disponible', 'sous_option'));

-- Property images: follow property access
CREATE POLICY "Property images follow property" ON public.property_images
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM public.properties WHERE id = property_id AND owner_id = auth.uid())
  );

CREATE POLICY "Public can view property images" ON public.property_images
  FOR SELECT TO authenticated USING (
    EXISTS (SELECT 1 FROM public.properties WHERE id = property_id AND status IN ('disponible', 'sous_option'))
  );

-- Favorites: users manage their own
CREATE POLICY "Users manage own favorites" ON public.property_favorites
  FOR ALL TO authenticated USING (user_id = auth.uid());

-- Visits: service owner can manage
CREATE POLICY "Service owner manages visits" ON public.property_visits
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM public.professional_services WHERE id = professional_service_id AND user_id = auth.uid())
  );

-- Contacts: service owner can manage
CREATE POLICY "Service owner manages contacts" ON public.property_contacts
  FOR ALL TO authenticated USING (
    EXISTS (SELECT 1 FROM public.professional_services WHERE id = professional_service_id AND user_id = auth.uid())
  );

-- Indexes
CREATE INDEX idx_properties_service ON public.properties(professional_service_id);
CREATE INDEX idx_properties_offer_type ON public.properties(offer_type);
CREATE INDEX idx_properties_city ON public.properties(city);
CREATE INDEX idx_properties_status ON public.properties(status);
CREATE INDEX idx_property_images_property ON public.property_images(property_id);
CREATE INDEX idx_property_favorites_user ON public.property_favorites(user_id);
CREATE INDEX idx_property_visits_service ON public.property_visits(professional_service_id);
CREATE INDEX idx_property_contacts_service ON public.property_contacts(professional_service_id);
